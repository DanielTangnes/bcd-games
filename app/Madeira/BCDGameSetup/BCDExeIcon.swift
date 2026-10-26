// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import CoreGraphics
import Foundation
import ImageIO

// Game setup (round 604, C15): the icon of a Windows program, for a game that has no store picture. Written from Microsoft's
// published PE and icon-resource formats. Foundation, CoreGraphics and ImageIO only, so tests/host/check-game-setup.py runs it on the
// Mac against real programs (the shipped 7-Zip among them).
//
// The program is only read: its optional header, section table and resource tree are walked with every offset checked, the first
// icon group is chosen, and its largest picture is wrapped in an .ico file that ImageIO decodes (PNG pictures as they are, bitmaps as
// the .ico format stores them). Nothing in the file is run or changed. The cover is a 600 x 900 picture (the shape of a store's
// library cover): the icon in the middle of a gradient made from its own colours.

enum BCDExeIcon {
    struct Found: Equatable {
        /// A single-image .ico file.
        var ico: Data
        /// The picture's width and height in pixels, as the group says (256 for a 256 x 256 picture).
        var width: Int
        var height: Int
        var isPNG: Bool
    }

    static let maxProgramBytes = 2 << 30
    private static let maxResource = 8 << 20

    // MARK: Reading the program

    private struct Reader {
        let data: Data
        func u8(_ o: Int) -> Int? { o >= 0 && o + 1 <= data.count ? Int(data[data.startIndex + o]) : nil }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= data.count else { return nil }
            return Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8
        }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return lo | hi << 16
        }
        func bytes(_ o: Int, _ n: Int) -> Data? {
            guard o >= 0, n >= 0, o + n <= data.count else { return nil }
            return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + n))
        }
    }

    private struct Section { var virtualAddress: Int; var virtualSize: Int; var rawOffset: Int; var rawSize: Int }

    /// The best icon of the program in `data`, or nil when it has none (or is not a PE file).
    static func find(in data: Data) -> Found? {
        let r = Reader(data: data)
        guard data.count > 0x100, r.u16(0) == 0x5A4D, let peOffset = r.u32(0x3C), peOffset > 0, r.u32(peOffset) == 0x4550 else { return nil }
        guard let sectionCount = r.u16(peOffset + 6), let optionalSize = r.u16(peOffset + 20), (1...96).contains(sectionCount) else { return nil }
        let optional = peOffset + 24
        guard let magic = r.u16(optional) else { return nil }
        let directories = optional + (magic == 0x20B ? 112 : 96)
        guard magic == 0x20B || magic == 0x10B, let resourceRVA = r.u32(directories + 2 * 8), let resourceSize = r.u32(directories + 2 * 8 + 4),
              resourceRVA > 0, resourceSize > 16 else { return nil }
        var sections: [Section] = []
        let table = optional + optionalSize
        for i in 0..<sectionCount {
            let s = table + 40 * i
            guard let vsize = r.u32(s + 8), let va = r.u32(s + 12), let rawSize = r.u32(s + 16), let raw = r.u32(s + 20) else { return nil }
            sections.append(Section(virtualAddress: va, virtualSize: vsize, rawOffset: raw, rawSize: rawSize))
        }
        func offset(_ rva: Int) -> Int? {
            for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress + max(s.virtualSize, s.rawSize) {
                let o = s.rawOffset + (rva - s.virtualAddress)
                return o < data.count ? o : nil
            }
            return nil
        }
        guard let root = offset(resourceRVA) else { return nil }

        /// The entries of a resource directory at `at` (relative to the root): (id or name offset, target offset, is a subdirectory).
        func entries(_ at: Int) -> [(id: Int, named: Bool, target: Int, directory: Bool)] {
            guard at >= 0, at < resourceSize, let named = r.u16(root + at + 12), let ids = r.u16(root + at + 14), named + ids <= 1024 else { return [] }
            var out: [(Int, Bool, Int, Bool)] = []
            for i in 0..<(named + ids) {
                let e = root + at + 16 + 8 * i
                guard let name = r.u32(e), let target = r.u32(e + 4) else { return out }
                out.append((name & 0x7FFF_FFFF, name & 0x8000_0000 != 0, target & 0x7FFF_FFFF, target & 0x8000_0000 != 0))
            }
            return out
        }
        /// The bytes of the first data entry below a resource node: leaves are reached through the node's first entries.
        func leaf(_ node: (id: Int, named: Bool, target: Int, directory: Bool)) -> Data? {
            var current = node
            for _ in 0..<4 {
                if !current.directory {
                    let d = root + current.target
                    guard let rva = r.u32(d), let size = r.u32(d + 4), size > 0, size <= maxResource, let o = offset(rva) else { return nil }
                    return r.bytes(o, size)
                }
                guard let next = entries(current.target).first else { return nil }
                current = next
            }
            return nil
        }
        func type(_ id: Int) -> [(id: Int, named: Bool, target: Int, directory: Bool)] {
            guard let node = entries(0).first(where: { !$0.named && $0.id == id && $0.directory }) else { return [] }
            return entries(node.target)
        }

        // The first icon group (lowest id), and its best picture.
        guard let group = type(14).filter({ !$0.named }).min(by: { $0.id < $1.id }), let groupData = leaf(group) else { return nil }
        let g = Reader(data: groupData)
        guard g.u16(0) == 0, g.u16(2) == 1, let count = g.u16(4), (1...64).contains(count) else { return nil }
        struct Candidate { var width: Int; var height: Int; var bits: Int; var id: Int }
        var candidates: [Candidate] = []
        for i in 0..<count {
            let e = 6 + 14 * i
            guard let w = g.u8(e), let h = g.u8(e + 1), let bits = g.u16(e + 6), let id = g.u16(e + 12) else { break }
            candidates.append(Candidate(width: w == 0 ? 256 : w, height: h == 0 ? 256 : h, bits: bits, id: id))
        }
        let icons = type(3).filter { !$0.named }
        // Largest first, then the most colours; one the file does not hold is skipped.
        for c in candidates.sorted(by: { ($0.width, $0.bits) > ($1.width, $1.bits) }) {
            guard let node = icons.first(where: { $0.id == c.id }), let picture = leaf(node), picture.count > 16 else { continue }
            let isPNG = picture.starts(with: [0x89, 0x50, 0x4E, 0x47])
            var ico = Data([0, 0, 1, 0, 1, 0])
            ico.append(contentsOf: [UInt8(c.width == 256 ? 0 : c.width), UInt8(c.height == 256 ? 0 : c.height), 0, 0, 1, 0,
                                    UInt8(c.bits & 0xFF), UInt8(c.bits >> 8 & 0xFF)])
            var size = UInt32(picture.count).littleEndian
            ico.append(Data(bytes: &size, count: 4))
            var start = UInt32(22).littleEndian
            ico.append(Data(bytes: &start, count: 4))
            ico.append(picture)
            return Found(ico: ico, width: c.width, height: c.height, isPNG: isPNG)
        }
        return nil
    }

    /// The icon of the program at `url` (read through a memory map; a file over 2 GB is not looked at).
    static func find(at url: URL) -> Found? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 0x100, size <= maxProgramBytes,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return find(in: data)
    }
}

enum BCDExeIconCover {
    static let width = 600, height = 900

    /// The cover as PNG bytes: the icon in the middle of a gradient of its own colours (dark at the foot). nil when ImageIO
    /// cannot read the .ico.
    static func png(fromICO ico: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(ico as CFData, nil), CGImageSourceGetCount(source) > 0,
              let icon = CGImageSourceCreateImageAtIndex(source, 0, nil), icon.width > 0, icon.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let tint = average(icon)
        let top = CGColor(colorSpace: space, components: [tint.0 * 0.45 + 0.04, tint.1 * 0.45 + 0.04, tint.2 * 0.45 + 0.05, 1])!
        let foot = CGColor(colorSpace: space, components: [0.03 + tint.0 * 0.06, 0.03 + tint.1 * 0.06, 0.05 + tint.2 * 0.06, 1])!
        if let gradient = CGGradient(colorsSpace: space, colors: [top, foot] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: 0), options: [])
        }
        // The icon in a 300-point box, a little above the middle, with a soft shadow; its shape kept.
        let box: CGFloat = 300
        let scale = min(box / CGFloat(icon.width), box / CGFloat(icon.height))
        let w = CGFloat(icon.width) * scale, h = CGFloat(icon.height) * scale
        context.interpolationQuality = .high
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(colorSpace: space, components: [0, 0, 0, 0.55])!)
        context.draw(icon, in: CGRect(x: (CGFloat(width) - w) / 2, y: CGFloat(height) * 0.5 - h / 2 + 30, width: w, height: h))
        guard let picture = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// The icon's mean colour where it is opaque (0...1 each), a mid grey for an icon with none.
    private static func average(_ image: CGImage) -> (CGFloat, CGFloat, CGFloat) {
        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let raw = context.data else { return (0.3, 0.3, 0.35) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let p = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in 0..<(side * side) {
            let a = Double(p[i * 4 + 3]) / 255
            guard a > 0.4 else { continue }
            // Premultiplied: divide the alpha out.
            r += Double(p[i * 4]) / 255 / a; g += Double(p[i * 4 + 1]) / 255 / a; b += Double(p[i * 4 + 2]) / 255 / a
            weight += 1
        }
        guard weight > 0 else { return (0.3, 0.3, 0.35) }
        return (CGFloat(min(1, r / weight)), CGFloat(min(1, g / weight)), CGFloat(min(1, b / weight)))
    }
}
