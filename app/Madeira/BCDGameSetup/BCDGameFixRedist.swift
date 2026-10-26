// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604): the reader behind a game fix's `redist` action. It takes one DLL out of a redistributable the game
// itself ships: a .cab (stored or MSZIP: BCDCab.c; LZX cabinets such as Microsoft's DirectX June 2010 are refused, never guessed
// at), a .zip, or a program or installer that holds cabinets (every "MSCF" in the file is looked at, as VCRuntimeDownload does,
// and a cabinet inside a cabinet too). Nothing is written here: the bytes go back to the fix runner, which checks them (a DLL, at
// most 64 MB) and places them in the game's folder. The source is a file already on the device: nothing is downloaded.

enum BCDGameFixRedist {
    static let maxSource = 400 << 20
    static let maxMember = 64 << 20

    struct Failure: LocalizedError {
        var text: String
        var errorDescription: String? { text }
    }

    static let extractMember: (URL, String) throws -> Data = { source, member in try extract(from: source, member: member) }

    private static func base(_ name: String) -> String {
        String(name.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(name)).lowercased()
    }

    static func extract(from source: URL, member: String) throws -> Data {
        let want = base(member)
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        guard size > 0, size <= maxSource else { throw Failure(text: "\(source.lastPathComponent) is empty or over \(maxSource >> 20) MB") }

        if source.pathExtension.lowercased() == "zip" {
            let zip = try SaveZipReader(url: source)
            guard let entry = zip.entries.first(where: { base($0.name) == want }) else { throw Failure(text: "\(member) is not in \(source.lastPathComponent)") }
            guard entry.size <= maxMember else { throw Failure(text: "\(member) is too big") }
            return try zip.extract(entry)
        }

        let file = try Data(contentsOf: source, options: .alwaysMapped)
        var found: Data?
        var sawLZX = false
        try file.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let start = raw.baseAddress else { return }
            var from = 0
            while found == nil, from < raw.count {
                let at = Int(bcd_cab_find(start, raw.count, from))
                if at < 0 { break }
                var handle: OpaquePointer?
                let opened = bcd_cab_open(start + at, raw.count - at, &handle)
                guard opened == BCD_CAB_OK, let cab = handle else {
                    if opened == BCD_CAB_ERR_UNSUPPORTED { sawLZX = true }
                    from = at + 1
                    continue
                }
                defer { bcd_cab_close(cab) }
                found = try take(from: cab, want: want, depth: 0)
                from = at + max(1, Int(bcd_cab_size(cab)))
            }
        }
        if let found { return found }
        if sawLZX { throw Failure(text: "\(source.lastPathComponent) holds a compression BCD cannot read (LZX)") }
        throw Failure(text: "\(member) is not in \(source.lastPathComponent)")
    }

    private static func take(from cab: OpaquePointer, want: String, depth: Int) throws -> Data? {
        let count = bcd_cab_count(cab)
        for index in 0..<count {
            guard let stored = bcd_cab_name(cab, index) else { continue }
            let name = base(String(cString: stored))
            let size = Int(bcd_cab_file_size(cab, index))
            if name == want {
                guard size > 0, size <= maxMember else { throw Failure(text: "\(want) is too big") }
                var payload = Data(count: size)
                let rc = payload.withUnsafeMutableBytes { bcd_cab_extract(cab, index, $0.baseAddress, $0.count) }
                if rc == BCD_CAB_ERR_UNSUPPORTED { throw Failure(text: "the cabinet holds a compression BCD cannot read (LZX)") }
                guard rc == BCD_CAB_OK else { throw Failure(text: "the cabinet is damaged (\(String(cString: bcd_cab_error(rc))))") }
                return payload
            }
            // A cabinet in a cabinet (Microsoft's installers nest them), one level.
            if depth == 0, size >= 36, size <= 200 << 20, name.hasSuffix(".cab") {
                var inner = Data(count: size)
                let rc = inner.withUnsafeMutableBytes { bcd_cab_extract(cab, index, $0.baseAddress, $0.count) }
                guard rc == BCD_CAB_OK, inner.starts(with: [0x4D, 0x53, 0x43, 0x46]) else { continue }
                let hit: Data? = try inner.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
                    var handle: OpaquePointer?
                    guard bcd_cab_open(raw.baseAddress, raw.count, &handle) == BCD_CAB_OK, let nested = handle else { return nil }
                    defer { bcd_cab_close(nested) }
                    return try take(from: nested, want: want, depth: 1)
                }
                if let hit { return hit }
            }
        }
        return nil
    }
}
