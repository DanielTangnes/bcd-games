// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import CoreGraphics
import Foundation
import ImageIO

// Game setup (round 604, C12): a picture from Files as the Wine desktop's wallpaper. Wine's desktop draws only bitmap (.bmp) files, centred
// (dlls/user32/desktop.c: LoadImageW with IMAGE_BITMAP), so the picture is cut to the desktop's own size (it fills, centred, nothing
// stretched out of shape) and written as a 24-bit .bmp. Foundation, CoreGraphics and ImageIO only; tests/host/check-game-setup.py runs it.

enum BCDWallpaper {
    static let maxPictureBytes = 40 << 20
    static let maxSide = 4096

    /// The desktop's size from a Resolution value ("1408x648"); nil when it is not one.
    static func size(_ resolution: String) -> (width: Int, height: Int)? {
        let parts = resolution.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, (320...maxSide).contains(parts[0]), (240...maxSide).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// The picture at `url` as a 24-bit .bmp of exactly width x height, or nil when ImageIO cannot read it.
    static func bmp(from url: URL, width: Int, height: Int) -> Data? {
        guard (1...maxSide).contains(width), (1...maxSide).contains(height),
              let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes <= maxPictureBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil), picture.width > 0, picture.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let raw = context.data else { return nil }
        // Fill: the picture covers the desktop, its middle kept.
        let scale = max(CGFloat(width) / CGFloat(picture.width), CGFloat(height) / CGFloat(picture.height))
        let w = CGFloat(picture.width) * scale, h = CGFloat(picture.height) * scale
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        // BMP rows run bottom-up, blue-green-red, padded to four bytes.
        let rowBytes = (width * 3 + 3) & ~3
        let imageBytes = rowBytes * height
        var out = Data(capacity: 54 + imageBytes)
        func le32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; out.append(Data(bytes: &x, count: 2)) }
        out.append(contentsOf: [0x42, 0x4D]); le32(54 + imageBytes); le32(0); le32(54)
        le32(40); le32(width); le32(height); le16(1); le16(24); le32(0); le32(imageBytes); le32(2835); le32(2835); le32(0); le32(0)
        let p = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var row = [UInt8](repeating: 0, count: rowBytes)
        for k in 0..<height {
            // Memory row 0 is the top of the picture, so the first row a BMP stores (its bottom) is the last row in memory.
            let base = (height - 1 - k) * width * 4
            for x in 0..<width {
                let a = Int(p[base + x * 4 + 3])
                // Premultiplied: divide the alpha out (the picture is drawn over opaque black, so it is 255 everywhere).
                func channel(_ i: Int) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(p[base + x * 4 + i]) * 255 / a)) }
                row[x * 3] = channel(2); row[x * 3 + 1] = channel(1); row[x * 3 + 2] = channel(0)
            }
            out.append(contentsOf: row)
        }
        return out
    }
}
