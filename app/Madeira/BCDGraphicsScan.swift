// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// What a game's own folder says about the Direct3D it uses (round 602, 2026-10-25).
//
// The question this answers: does a 64-bit program in this folder use Direct3D 9 AND is nothing in the folder a Direct3D 11, DXGI or
// Direct3D 12 program? Only then BCD's 64-bit Direct3D 9 (DXMT, BCDGraphicsDefaults.swift) becomes the game's default instead of Wine's,
// which needs OpenGL and so ends in "Direct3DCreate9 called -> d3d9_init FAILED" on a phone. Every other game keeps Wine's d3d9.dll, byte
// for byte: when the folder shows Direct3D 11, DXGI or Direct3D 12 anywhere, or the scan cannot finish, or a web engine (Chromium) is in
// the folder, the answer is "unchanged".
//
// How it looks, in two passes over the program files (.exe and .dll) of the folder tree:
//  1. The PE import tables (static and delay-load imports), a few kilobytes of each file. A program that imports d3d11.dll, dxgi.dll or
//     d3d12.dll ends the scan at once: that is every Direct3D 11 and 12 game and most Unity and Unreal games.
//  2. The text of each file, ASCII and UTF-16, for the names a program loads at run time (LoadLibrary "d3d11.dll", GetProcAddress
//     "D3D11CreateDevice"; Unity's UnityPlayer.dll and Unreal's modules do this). The scan is bounded (bytes per file, bytes in all, files,
//     time): when a bound is hit the folder is "unsure" and nothing changes.
//
// Pure Foundation, no app types, so tests/host/check-d3d9-x64-default.py compiles this very file and runs it on synthetic folders.
enum BCDGraphicsScan {
    struct Limits {
        var entries = 150_000                // directory entries looked at
        var images = 3_000                   // .exe and .dll files read
        var perFileBytes = 400 << 20         // the text pass skips nothing: a larger file makes the scan unsure
        var totalBytes = 1 << 30             // bytes read by the text pass
        var seconds = 4.0                    // wall clock (a launch waits for it)
        init() {}
    }

    struct Result {
        var complete = true
        var incompleteReason = ""
        var imagesRead = 0
        var bytesRead = 0
        /// The first file that shows Direct3D 11, DXGI or Direct3D 12 ("Game.exe imports d3d11.dll"), nil if none did.
        var modern: String?
        /// The first Chromium/web-engine file ("libcef.dll"); such a folder is left alone.
        var webEngine: String?
        /// The first 64-bit and the first 32-bit program that shows Direct3D 9 ("Game64.exe imports d3d9.dll").
        var d3d9x64: String?
        var d3d9x86: String?
    }

    /// Folders that hold redistributables and installers, not the game: DXSETUP.exe and the like name every DirectX DLL.
    static let skippedFolders: Set<String> = ["_commonredist", "redist", "redistributable", "redistributables", "vcredist", "directx", "__installer", "installer", "dotnetfx"]
    /// A Chromium Embedded Framework folder (a launcher or a game with a web UI) carries ANGLE and Direct3D 11 strings of its own.
    static let webEngineFiles: Set<String> = ["libcef.dll", "chrome_elf.dll", "libglesv2.dll", "libegl.dll"]

    // MARK: - PE import tables

    struct PEInfo {
        var machine: UInt16
        var imports: Set<String>   // lowercased DLL names, static and delay-load
        var is64: Bool { machine == 0x8664 || machine == 0xaa64 || machine == 0xa641 }
    }

    /// The machine and the imported DLL names of a PE file, nil when it is not one (or cannot be read).
    static func inspect(_ url: URL) -> PEInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count) ?? Data() } catch { return Data() }
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
        }
        let dos = read(0, 64)
        guard dos.count == 64, dos[dos.startIndex] == 0x4d, dos[dos.startIndex + 1] == 0x5a else { return nil }
        let base = UInt64(u32(dos, 60))
        guard base >= 64, base < 16 * 1024 * 1024 else { return nil }
        let header = read(base, 264)
        guard header.count >= 120, u32(header, 0) == 0x4550 else { return nil }
        let machine = UInt16(header[header.startIndex + 4]) | UInt16(header[header.startIndex + 5]) << 8
        let sections = Int(header[header.startIndex + 6]) | Int(header[header.startIndex + 7]) << 8
        let optSize = Int(header[header.startIndex + 20]) | Int(header[header.startIndex + 21]) << 8
        var info = PEInfo(machine: machine, imports: [])
        guard sections > 0, sections <= 96, optSize >= 120, header.count >= 26 else { return info }
        let magic = UInt16(header[header.startIndex + 24]) | UInt16(header[header.startIndex + 25]) << 8
        guard magic == 0x10b || magic == 0x20b else { return info }
        let pe64 = magic == 0x20b
        guard header.count >= (pe64 ? 148 : 132) else { return info }
        let imports = u32(header, pe64 ? 144 : 128)
        let delayed = optSize >= (pe64 ? 224 : 208) && header.count >= (pe64 ? 244 : 228) ? u32(header, pe64 ? 240 : 224) : 0
        let table = read(base + 24 + UInt64(optSize), sections * 40)
        guard table.count == sections * 40 else { return info }
        func fileOffset(_ rva: UInt32) -> UInt64? {
            for index in 0..<sections {
                let i = index * 40, va = u32(table, i + 12), size = max(u32(table, i + 8), u32(table, i + 16))
                if rva >= va, rva - va < size { return UInt64(u32(table, i + 20)) + UInt64(rva - va) }
            }
            return nil
        }
        for (rva, stride, nameField) in [(imports, 20, 12), (delayed, 32, 4)] {
            guard rva != 0, let start = fileOffset(rva) else { continue }
            for i in 0..<512 {
                let descriptor = read(start + UInt64(i * stride), stride)
                guard descriptor.count == stride else { break }
                var nameRVA = u32(descriptor, nameField)
                if nameRVA == 0 { break }
                if stride == 32 && u32(descriptor, 0) & 1 == 0 {
                    // An old delay-load descriptor holds virtual addresses, not RVAs.
                    let imageBase = u32(header, 52)
                    guard !pe64, nameRVA >= imageBase else { continue }
                    nameRVA -= imageBase
                }
                guard let offset = fileOffset(nameRVA) else { continue }
                let data = read(offset, 128)
                let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self).lowercased()
                if !name.isEmpty { info.imports.insert(name) }
            }
        }
        return info
    }

    // MARK: - text pass

    /// What the text of a file names. Each needle is matched case-insensitively as ASCII and, for the DLL names, also as UTF-16LE.
    struct Mentions: OptionSet {
        let rawValue: Int
        static let d3d11 = Mentions(rawValue: 1)
        static let dxgi = Mentions(rawValue: 2)
        static let d3d12 = Mentions(rawValue: 4)
        static let d3d9 = Mentions(rawValue: 8)
        static let modern: Mentions = [.d3d11, .dxgi, .d3d12]
    }

    private struct Needle {
        let bytes: [UInt8]      // lowercase
        let flag: Mentions
        let wide: Bool          // also match it as UTF-16LE
    }
    private static let needles: [Needle] = [
        Needle(bytes: Array("d3d11.dll".utf8), flag: .d3d11, wide: true), Needle(bytes: Array("dxgi.dll".utf8), flag: .dxgi, wide: true),
        Needle(bytes: Array("d3d12.dll".utf8), flag: .d3d12, wide: true), Needle(bytes: Array("d3d9.dll".utf8), flag: .d3d9, wide: true),
        Needle(bytes: Array("d3d11createdevice".utf8), flag: .d3d11, wide: false), Needle(bytes: Array("createdxgifactory".utf8), flag: .dxgi, wide: false),
        Needle(bytes: Array("d3d12createdevice".utf8), flag: .d3d12, wide: false), Needle(bytes: Array("direct3dcreate9".utf8), flag: .d3d9, wide: false),
    ]
    /// The longest needle in bytes (17), so a chunk keeps twice that as the overlap with the next (UTF-16 doubles a name).
    static let longestNeedle = 17

    /// What `buffer` names, in one pass over the bytes: only a 'd' or a 'c' (any case) starts a name, so the common byte costs a compare or two.
    /// Stops at the first Direct3D 11, DXGI or Direct3D 12 name (the answer is "unchanged" then).
    static func mentions(in buffer: UnsafeRawBufferPointer) -> Mentions {
        var found: Mentions = []
        guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return found }
        let count = buffer.count
        @inline(__always) func fold(_ byte: UInt8) -> UInt8 { byte &- 65 < 26 ? byte &+ 32 : byte }
        var i = 0
        while i < count {
            let lead = fold(base[i])
            if lead == 0x64 || lead == 0x63 {
                for needle in needles where needle.bytes[0] == lead {
                    let n = needle.bytes.count
                    if i + n <= count {
                        var k = 1
                        while k < n && fold(base[i + k]) == needle.bytes[k] { k += 1 }
                        if k == n { found.insert(needle.flag) }
                    }
                    if needle.wide, i + 2 * n <= count, base[i + 1] == 0 {
                        var w = 1
                        while w < n && fold(base[i + 2 * w]) == needle.bytes[w] && base[i + 2 * w + 1] == 0 { w += 1 }
                        if w == n { found.insert(needle.flag) }
                    }
                }
                if !found.intersection(.modern).isEmpty { return found }
            }
            i += 1
        }
        return found
    }

    /// Reads `url` in chunks and returns what its text names; nil if it cannot be read completely.
    static func mentions(of url: URL, size: Int, bytesRead: inout Int) -> Mentions? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let chunk = 4 << 20, overlap = 2 * longestNeedle
        var found: Mentions = []
        var tail = Data()
        var consumed = 0
        while consumed < size {
            guard let data = try? h.read(upToCount: chunk), !data.isEmpty else { break }
            consumed += data.count
            bytesRead += data.count
            var window = tail
            window.append(data)
            window.withUnsafeBytes { found.formUnion(mentions(in: $0)) }
            if !found.intersection(.modern).isEmpty { break }
            tail = Data(window.suffix(overlap))
        }
        return found
    }

    // MARK: - the scan

    /// Looks at the program files below `root`. Never follows a symbolic link, never writes. The files beside the root are looked at first, and
    /// every program is read the moment it is found, so a Direct3D 11 or 12 game ends the scan at its first such file instead of after the walk.
    static func scan(_ root: URL, limits: Limits = Limits(), now: () -> Date = Date.init) -> Result {
        var result = Result()
        let started = now()
        func late() -> Bool { now().timeIntervalSince(started) > limits.seconds }
        func unsure(_ why: String) -> Result { result.complete = false; if result.incompleteReason.isEmpty { result.incompleteReason = why }; return result }
        let manager = FileManager.default
        var readable: [(url: URL, size: Int, info: PEInfo)] = []
        var looked = Set<String>()

        // Reads one program's import tables (pass 1); true when it shows Direct3D 11, DXGI or Direct3D 12.
        func look(_ url: URL, size: Int) -> Bool {
            guard looked.insert(url.path).inserted, let info = inspect(url) else { return false }
            result.imagesRead += 1
            readable.append((url, size, info))
            let file = url.lastPathComponent
            for dll in ["d3d11.dll", "dxgi.dll", "d3d12.dll"] where info.imports.contains(dll) {
                result.modern = "\(file) imports \(dll)"
                return true
            }
            if info.imports.contains("d3d9.dll") {
                let note = "\(file) imports d3d9.dll"
                if info.is64 { if result.d3d9x64 == nil { result.d3d9x64 = note } } else if result.d3d9x86 == nil { result.d3d9x86 = note }
            }
            return false
        }
        func isProgram(_ name: String) -> Bool { let ext = (name as NSString).pathExtension.lowercased(); return ext == "exe" || ext == "dll" }

        // 1. The files right beside the root: most games name their graphics DLLs there.
        let beside = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [])) ?? []
        for item in beside {
            let name = item.lastPathComponent.lowercased()
            if webEngineFiles.contains(name) { result.webEngine = name; return result }
        }
        for item in beside where isProgram(item.lastPathComponent) {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if look(item, size: values.fileSize ?? 0) { return result }
        }

        // 2. The whole tree.
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        var failed = false
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in failed = true; return true }) else {
            return unsure("the folder cannot be listed")
        }
        var entries = 0, programs = 0
        while let item = walker.nextObject() as? URL {
            entries += 1
            if entries > limits.entries { return unsure("more than \(limits.entries) entries") }
            if entries % 256 == 0, late() { return unsure("the time limit") }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { failed = true; continue }
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            let name = item.lastPathComponent.lowercased()
            if values.isDirectory == true {
                if skippedFolders.contains(name) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if webEngineFiles.contains(name) { result.webEngine = name; return result }
            if isProgram(name) {
                programs += 1
                if programs > limits.images { return unsure("more than \(limits.images) program files") }
                if look(item, size: values.fileSize ?? 0) { return result }
            }
        }
        if failed { return unsure("part of the folder could not be read") }

        // Pass 2: the text, smallest files first.
        for image in readable.sorted(by: { $0.size < $1.size }) {
            if late() { return unsure("the time limit") }
            if image.size > limits.perFileBytes { return unsure("\(image.url.lastPathComponent) is larger than \(limits.perFileBytes >> 20) MB") }
            if result.bytesRead + image.size > limits.totalBytes { return unsure("more than \(limits.totalBytes >> 20) MB of program files") }
            guard let found = mentions(of: image.url, size: image.size, bytesRead: &result.bytesRead) else { return unsure("\(image.url.lastPathComponent) cannot be read") }
            let file = image.url.lastPathComponent
            if !found.intersection(.modern).isEmpty {
                let what = found.contains(.d3d11) ? "d3d11" : found.contains(.dxgi) ? "dxgi" : "d3d12"
                result.modern = "\(file) names \(what)"
                return result
            }
            if found.contains(.d3d9) {
                let note = "\(file) names d3d9"
                if image.info.is64 { if result.d3d9x64 == nil { result.d3d9x64 = note } } else if result.d3d9x86 == nil { result.d3d9x86 = note }
            }
        }
        return result
    }

    /// The answer: DXMT's Direct3D 9 for this folder's 64-bit program, or unchanged, and the sentence for the log.
    static func decide(_ r: Result) -> (dxmt: Bool, why: String) {
        if let web = r.webEngine { return (false, "\(web) is in the folder (a web engine; Direct3D 11 is likely there)") }
        if let modern = r.modern { return (false, modern) }
        if !r.complete { return (false, "not sure: \(r.incompleteReason)") }
        if r.imagesRead == 0 { return (false, "no program file was read") }
        guard let d9 = r.d3d9x64 else {
            return (false, r.d3d9x86 != nil ? "only 32-bit programs show Direct3D 9 (\(r.d3d9x86!))" : "no program shows Direct3D 9")
        }
        return (true, "\(d9) in a 64-bit program, and none of \(r.imagesRead) program files shows Direct3D 11, DXGI or Direct3D 12")
    }

    /// The folder to look at for a program: its own, or the installation root above a conventional binary folder (bin, x64, Win64...), as the
    /// library's metadata scan does. `inside` says whether a folder is one the library may read (drive_c, or the SSD folder).
    static func installationRoot(of program: URL, inside: (URL) -> Bool, stopAt: (URL) -> Bool) -> URL {
        var root = program.deletingLastPathComponent()
        let binaryFolders: Set<String> = ["bin", "binaries", "win32", "win64", "x86", "x64", "release"]
        for _ in 0..<4 {
            guard binaryFolders.contains(root.lastPathComponent.lowercased()) else { break }
            let parent = root.deletingLastPathComponent()
            guard inside(parent), !stopAt(parent),
                  !["program files", "program files (x86)", "games", "common", "steamapps"].contains(parent.lastPathComponent.lowercased()) else { break }
            root = parent
        }
        return root
    }
}
