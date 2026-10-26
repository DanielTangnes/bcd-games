// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604, C2): the Windows prefix as a kit that can be copied, exported, imported and put back. The kit is the part of
// the prefix that is the player's and not Wine's: the three registry files, the Windows users' folders, C:\ProgramData and two small
// BCD files (the prefix's seed stamp and the registry state of the game setup). Caches and logs inside them are left out, and
// links (saves moved to Game Saves) are carried as links in a copy and left out of a zip. The games, Wine's own files and the farm
// links are not part of it: they are as big as the device and come from the app.
//
// Foundation only (it uses the app's zip writer and reader and the save rules), tests/host/check-game-setup.py runs it on a scratch
// prefix. What it never does: run while a session does (the caller checks; the wineserver keeps the registry in memory), touch the
// games or anything under C:\External (an external drive's games are not in the kit), write outside the prefix's own parts on an
// import, or replace without a copy: the caller makes the "Before ..." copy first, and every operation here stops at the first error
// and says which one.

enum BCDPrefixKit {
    static let manifestName = "bcd-prefix.json"
    /// Files at the top of the prefix.
    static let topFiles = ["system.reg", "user.reg", "userdef.reg", ".update-timestamp", ".bcd-setup-state.json"]
    /// Folders below the prefix.
    static let folders = ["drive_c/users", "drive_c/ProgramData"]
    static let maxFiles = 40_000
    static let maxBytes: Int64 = 1 << 30

    struct Failure: LocalizedError {
        var text: String
        var errorDescription: String? { text }
    }

    struct Entry: Equatable {
        var path: String        // relative to the prefix, "/"
        var url: URL
        var size: Int64
    }

    struct Listing: Equatable {
        var files: [Entry] = []
        var links: [String] = []
        var truncated = false
        var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    static func isSkipped(_ name: String) -> Bool { GameSaveRules.skippedFolders.contains(name.lowercased()) }

    // MARK: Looking

    /// The kit's files and links in `prefix`, without caches (folders GameSaveRules skips) and without what the limits cut.
    static func list(prefix: URL) -> Listing {
        let fm = FileManager.default
        var out = Listing()
        for name in topFiles {
            let url = prefix.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path), (attributes[.type] as? FileAttributeType) == .typeRegular else { continue }
            out.files.append(Entry(path: name, url: url, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        for folder in folders {
            let base = BCDFixPaths.onDisk(base: prefix, parts: folder.split(separator: "/").map(String.init))
            guard let walk = fm.enumerator(atPath: base.path) else { continue }
            let head = base.deletingLastPathComponent().lastPathComponent + "/" + base.lastPathComponent
            while let rel = walk.nextObject() as? String {
                if out.files.count >= maxFiles { out.truncated = true; break }
                let attributes = walk.fileAttributes
                let type = attributes?[.type] as? FileAttributeType
                let name = (rel as NSString).lastPathComponent
                if type == .typeDirectory {
                    if isSkipped(name) { walk.skipDescendants() }
                    continue
                }
                if type == .typeSymbolicLink { out.links.append(folder + "/" + rel); continue }
                guard type == .typeRegular else { continue }
                if rel.split(separator: "/").dropLast().contains(where: { isSkipped(String($0)) }) { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if GameSaveRules.noiseExtensions.contains(ext) { continue }
                _ = head
                out.files.append(Entry(path: folder + "/" + rel, url: base.appendingPathComponent(rel), size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        return out
    }

    /// The Windows users' folder names in the prefix (not Public).
    static func users(prefix: URL) -> [String] { BCDFixPaths.users(drive: prefix.appendingPathComponent("drive_c")) }

    // MARK: Manifest

    static func manifest(made: Date, users: [String]) -> Data {
        let object: [String: Any] = ["format": "bcd-prefix-kit", "version": 1, "made": GameSaveRules.isoUTC(made), "users": users]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func readManifest(_ data: Data) -> (made: String, users: [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] as? String == "bcd-prefix-kit",
              object["version"] as? Int == 1, let made = object["made"] as? String else { return nil }
        return (made, (object["users"] as? [String]) ?? [])
    }

    /// "2026-10-25 14.32.07": a copy's or an export's name (made from numbers, never with a date formatter).
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let c = GameSaveRules.civil(date, offset: timeZone.secondsFromGMT(for: date))
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(c.year)-\(two(c.month))-\(two(c.day)) \(two(c.hour)).\(two(c.minute)).\(two(c.second))"
    }

    // MARK: Copies (folders, cloned by the file system)

    struct Copy: Equatable, Identifiable {
        var name: String
        var url: URL
        var made: Date?
        var id: String { name }
    }

    static func copies(in folder: URL) -> [Copy] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [Copy] = []
        for name in names where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: url.appendingPathComponent(manifestName)), readManifest(data) != nil else { continue }
            let date = (try? fm.attributesOfItem(atPath: url.appendingPathComponent(manifestName).path))?[.modificationDate] as? Date
            out.append(Copy(name: name, url: url, made: date))
        }
        return out.sorted { ($0.made ?? .distantPast) > ($1.made ?? .distantPast) }
    }

    /// Copies the kit into `folder/<name>` (the name gets a number when taken). Files are cloned by the file system where it can.
    static func makeCopy(prefix: URL, into folder: URL, name: String, now: Date = Date()) throws -> (copy: Copy, files: Int, bytes: Int64) {
        let fm = FileManager.default
        let listing = list(prefix: prefix)
        guard !listing.files.isEmpty else { throw Failure(text: "The prefix has no registry or user files yet. Start a game or the Windows desktop once.") }
        guard !listing.truncated else { throw Failure(text: "The prefix's user files are more than a copy takes (\(maxFiles) files).") }
        var final = folder.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: final.path) { final = folder.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        let part = folder.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        do {
            for entry in listing.files {
                let target = part.appendingPathComponent(entry.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: entry.url, to: target)
            }
            // Links (saves moved to Game Saves) are links in the copy too, with the same relative target.
            for link in listing.links {
                let source = BCDFixPaths.onDisk(base: prefix, parts: link.split(separator: "/").map(String.init))
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: source.path) else { continue }
                let target = part.appendingPathComponent(link)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            }
            try manifest(made: now, users: users(prefix: prefix)).write(to: part.appendingPathComponent(manifestName))
            try fm.moveItem(at: part, to: final)
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
        return (Copy(name: final.lastPathComponent, url: final, made: now), listing.files.count, listing.bytes)
    }

    /// Puts a copy's files into the prefix, replacing files of the same names (other files stay).
    static func putBack(_ copy: URL, prefix: URL) throws -> Int {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: copy.appendingPathComponent(manifestName)), readManifest(data) != nil else { throw Failure(text: "That is not a copy BCD made.") }
        guard let walk = fm.enumerator(atPath: copy.path) else { throw Failure(text: "The copy cannot be read.") }
        var written = 0
        while let rel = walk.nextObject() as? String {
            guard rel != manifestName, !rel.hasSuffix(".bcd-part"), let parts = GameSaveRules.safeParts(rel), allowed(parts) else { continue }
            let source = copy.appendingPathComponent(rel)
            let type = walk.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory { continue }
            let target = BCDFixPaths.onDisk(base: prefix, parts: parts)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if type == .typeSymbolicLink {
                // A link is put back only where nothing is: a folder the game made since stays.
                if (try? fm.attributesOfItem(atPath: target.path)) == nil, let to = try? fm.destinationOfSymbolicLink(atPath: source.path) {
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: to)
                    written += 1
                }
                continue
            }
            guard type == .typeRegular else { continue }
            let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).bcd-part")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) } else { try fm.moveItem(at: staging, to: target) }
            written += 1
        }
        guard written > 0 else { throw Failure(text: "The copy holds no files.") }
        return written
    }

    /// A kit path (below the prefix) a copy or import may write.
    static func allowed(_ parts: [String]) -> Bool {
        if parts.count == 1 { return topFiles.contains(parts[0]) }
        guard parts.count >= 3, parts[0].lowercased() == "drive_c" else { return false }
        let second = parts[1].lowercased()
        return second == "users" || second == "programdata"
    }

    // MARK: Zip (export and import)

    /// Writes the kit's files as a stored zip with the manifest; links are left out (the saves they lead to are in Game Saves).
    static func exportZip(prefix: URL, to url: URL, now: Date = Date()) throws -> (files: Int, bytes: Int64, links: Int) {
        let listing = list(prefix: prefix)
        guard !listing.files.isEmpty else { throw Failure(text: "The prefix has no registry or user files yet.") }
        guard !listing.truncated, listing.bytes <= maxBytes else {
            throw Failure(text: "The prefix's user files are over \(maxBytes >> 20) MB or \(maxFiles) files: more than one zip takes. Make a copy instead.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = url.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: part) }
        let zip = try SaveZipWriter(url: part)
        var written = 0
        var bytes: Int64 = 0
        for entry in listing.files {
            guard let data = try? Data(contentsOf: entry.url) else { continue }   // gone meanwhile
            try zip.add(name: entry.path, data: data)
            written += 1
            bytes += Int64(data.count)
        }
        try zip.add(name: manifestName, data: manifest(made: now, users: users(prefix: prefix)))
        try zip.finish()
        guard written > 0 else { throw Failure(text: "The prefix's files could not be read.") }
        try fm.moveItem(at: part, to: url)
        return (written, bytes, listing.links.count)
    }

    /// What an import would do, read from the zip without writing anything.
    static func inspect(zip url: URL) throws -> (made: String, users: [String], files: Int) {
        let zip = try SaveZipReader(url: url)
        guard let entry = zip.entries.first(where: { $0.name == manifestName }), let data = try? zip.extract(entry), let info = readManifest(data) else {
            throw Failure(text: "That zip was not made by BCD's prefix export.")
        }
        let files = zip.entries.filter { !$0.name.hasSuffix("/") && $0.name != manifestName && GameSaveRules.safeParts($0.name).map(allowed) == true }.count
        return (info.made, info.users, files)
    }

    /// Writes a zip's kit files into the prefix, replacing files of the same names. Entries outside the kit are refused and counted.
    static func importZip(_ url: URL, prefix: URL) throws -> (written: Int, refused: Int) {
        _ = try inspect(zip: url)
        let zip = try SaveZipReader(url: url)
        let fm = FileManager.default
        var written = 0, refused = 0
        for entry in zip.entries where !entry.name.hasSuffix("/") && entry.name != manifestName {
            guard let parts = GameSaveRules.safeParts(entry.name), allowed(parts) else { refused += 1; continue }
            let target = BCDFixPaths.onDisk(base: prefix, parts: parts)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try zip.extract(entry)
            // A link in the way (a save folder moved to Game Saves) is not written through.
            if (try? fm.attributesOfItem(atPath: target.deletingLastPathComponent().path)) == nil { continue }
            try data.write(to: target, options: .atomic)
            written += 1
        }
        guard written > 0 else { throw Failure(text: "That zip holds no files BCD takes.") }
        return (written, refused)
    }

    // MARK: Reconfigure and the system files

    /// The prefix's Windows users must be the one the template's profile paths name (or none yet): a fresh registry for another user
    /// would leave the games' folders and saves behind in a profile it no longer names.
    static func requireUser(prefix: URL, templateUser: String) throws {
        let present = users(prefix: prefix)
        if let other = present.first(where: { $0.caseInsensitiveCompare(templateUser) != .orderedSame }) {
            throw Failure(text: "This prefix's Windows user is \"\(other)\", and a fresh registry names \"\(templateUser)\": the games' folders and saves would be left behind. Nothing was changed.")
        }
    }

    /// Replaces the three registry files with the template's, and forgets the setup's registry state (it described the old file).
    static func reconfigure(prefix: URL, template: URL, templateUser: String) throws {
        let fm = FileManager.default
        try requireUser(prefix: prefix, templateUser: templateUser)
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            guard fm.fileExists(atPath: template.appendingPathComponent(name).path) else { throw Failure(text: "BCD's template has no \(name).") }
        }
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            let target = prefix.appendingPathComponent(name)
            let staging = prefix.appendingPathComponent(".\(name).bcd-part")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: template.appendingPathComponent(name), to: staging)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staging) } else { try fm.moveItem(at: staging, to: target) }
        }
        try? fm.removeItem(at: prefix.appendingPathComponent(BCDRegistryEdit.stateName))
    }

    /// Puts back the template's files of Windows' own folder that are missing or empty in the prefix. Nothing that exists and has
    /// content is replaced (games keep settings in win.ini; the farm's DLLs are linked again at every start anyway). Returns how many.
    static func reinstallSystemFiles(prefix: URL, template: URL) throws -> Int {
        let fm = FileManager.default
        let windows = template.appendingPathComponent("drive_c/windows")
        guard let walk = fm.enumerator(atPath: windows.path) else { throw Failure(text: "BCD's template has no Windows folder.") }
        var put = 0
        while let rel = walk.nextObject() as? String {
            let type = walk.fileAttributes?[.type] as? FileAttributeType
            let source = windows.appendingPathComponent(rel)
            let target = prefix.appendingPathComponent("drive_c/windows").appendingPathComponent(rel)
            if type == .typeDirectory { try fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
            guard type == .typeRegular else { continue }
            let existing = try? fm.attributesOfItem(atPath: target.path)
            if let existing {
                guard (existing[.type] as? FileAttributeType) == .typeRegular, ((existing[.size] as? NSNumber)?.int64Value ?? 0) == 0 else { continue }
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            put += 1
        }
        return put
    }
}
