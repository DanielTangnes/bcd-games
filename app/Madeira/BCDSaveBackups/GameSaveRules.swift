// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Save backups per game (round 603): the rules, with nothing of the engine in them. Foundation only and pure
// (tests/host/check-game-saves.py compiles this file on the Mac and runs it): which files of a game's session are
// saves and where their folders are, how a backup is named and found again, what rotates away, what a restore may write.
//
// Where a game keeps its saves is not written down anywhere for most games. BCD learns it from what the game did: the
// files that changed in the prefix between the game's start and its end, under the places Windows games write to (the
// user's Documents, Saved Games and AppData, C:\ProgramData, the public Documents, and the game's own folder), minus caches,
// logs and the program's own files. Steam Cloud's list of a Steam game, when BCD has compared it, adds its folders.
// A "root" is the folder (or the single file) a save lives under; a backup holds every file under every root.

/// One place a game keeps its saves: a folder or one file, relative to drive_c ("users/user/Documents/My Games/Foo").
struct GameSaveRoot: Codable, Hashable {
    enum Source: String, Codable {
        /// Files of this place changed while the game ran.
        case played
        /// Steam Cloud lists files here for the game.
        case steamCloud
    }
    var path: String
    var isFile: Bool
    var source: Source
}

/// A file as the scan sees it: path from drive_c, size, modification time (seconds since 1970).
struct GameSaveFile: Hashable {
    var path: String
    var size: Int64
    var modified: TimeInterval
}

enum GameSaveKind: String, CaseIterable {
    case manual = "Manual"
    case automatic = "Automatic"
    case beforeRestore = "Before restore"
}

enum GameSaveRules {
    // MARK: Limits

    /// A file bigger than this is left out (a save is small; a video or a cache is not).
    static let maxFileBytes: Int64 = 128 << 20
    /// A backup bigger than this is not made: it would fill the device and the player did not ask for that.
    static let maxBackupBytes: Int64 = 512 << 20
    /// A backup of more files than this is not made (a zip holds 65,535 entries at most, and a save is a handful of files).
    static let maxBackupFiles = 20_000
    /// Entries a scan looks at before it stops (a game folder with more files than this is not searched).
    static let maxScanEntries = 60_000
    /// The number of automatic backups kept per game: this many newest stay; the oldest is replaced by the next.
    static let keepDefault = 5
    static let keepRange = 2...20
    /// A game's backup list shows this many; older ones stay in Files.
    static let listLimit = 20

    // MARK: What is not a save

    /// Folder names (lower case) that hold caches, logs, crash dumps or Windows' own files, never saves. A superset of
    /// SaveBackup.skipped (SavesAndShortcuts.swift), which the whole-prefix backup uses.
    static let skippedFolders: Set<String> = [
        "madeira", "temp", "tmp", "shadercache", "shadercaches", "d3dscache", "dxcache", "glcache", "nvidia", "nv_cache",
        "microsoft", "cache", "caches", "code cache", "gpucache", "crashdumps", "crashes", "crashpad", "logs", "log",
        "webcache", "steam", "htmlcache", "cef", "cefcache", "__pycache__", ".git", "wine", "mesa_shader_cache",
    ]
    /// Files (by extension, lower case) that are diagnostics or scratch space in any place.
    static let noiseExtensions: Set<String> = [
        "log", "dmp", "mdmp", "tmp", "temp", "etl", "pdb", "crash", "lock", "lck", "cache", "dxcache", "pyc", "swp",
    ]
    /// Files of the game itself, which a game's own folder holds and a session may touch without saving anything.
    static let programExtensions: Set<String> = [
        "exe", "dll", "sys", "msi", "cab", "ocx", "vpk", "pak", "bik", "bk2", "wem", "bnk", "ogg", "mp3", "wav", "mp4",
        "webm", "wmv", "avi", "bsa", "ba2", "dds", "tga", "png", "jpg", "jpeg", "ttf", "otf", "so", "dylib",
    ]

    /// Components of a path from drive_c; empty parts, "." and ".." make it nil.
    static func parts(_ path: String) -> [String]? {
        let list = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !list.isEmpty, !list.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { return nil }
        return list
    }

    /// A zip entry's path as parts under drive_c, or nil when it is not a plain relative path (absolute, empty parts,
    /// "..", a drive letter): nothing outside the prefix is ever written.
    static func safeParts(_ entry: String) -> [String]? {
        guard !entry.hasPrefix("/"), !entry.hasPrefix("\\"), let list = parts(entry), list.count <= 40,
              !list.contains(where: { $0.contains(":") || $0.utf8.count > 255 }) else { return nil }
        return list
    }

    // MARK: Where games write

    /// A folder games write to, relative to drive_c. `install`: the game's own folder.
    struct Base: Equatable {
        var path: String
        var install: Bool
    }

    /// The places a session's changes are looked for: for each Windows user the Documents, Saved Games and AppData folders,
    /// the public Documents, C:\ProgramData, and the game's folder (`install`, from drive_c, when it has one of its own).
    static func bases(users: [String], install: String?) -> [Base] {
        var list: [Base] = []
        for user in users where user.caseInsensitiveCompare("Public") != .orderedSame {
            let home = "users/" + user
            for sub in ["Documents", "Saved Games", "AppData/Roaming", "AppData/Local", "AppData/LocalLow", "Local Settings/Application Data"] {
                list.append(Base(path: home + "/" + sub, install: false))
            }
        }
        list.append(Base(path: "users/Public/Documents", install: false))
        list.append(Base(path: "ProgramData", install: false))
        if let install, !install.isEmpty { list.append(Base(path: install, install: true)) }
        return list
    }

    /// Is a file one to leave out? `rest`: its path below its base. `install`: the base is the game's own folder.
    static func isNoise(_ rest: [String], install: Bool) -> Bool {
        guard let name = rest.last else { return true }
        for folder in rest.dropLast() where skippedFolders.contains(folder.lowercased()) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if noiseExtensions.contains(ext) { return true }
        if install && programExtensions.contains(ext) { return true }
        if name.hasPrefix("~") || name.hasSuffix("~") { return true }
        return false
    }

    /// The roots the changed files point to. A file straight in a base is a root of its own (a file); the others group by the
    /// folder they are in below the base, and each group's root is the deepest folder they share, never shallower than the
    /// folder straight below the base and never deeper than two folders below it ("My Games/Skyrim", "Vendor/Game").
    static func roots(changed: [GameSaveFile], users: [String], install: String?, source: GameSaveRoot.Source) -> [GameSaveRoot] {
        let bases = bases(users: users, install: install)
        var groups: [String: (base: String, first: String, files: [[String]])] = [:]
        var out: [GameSaveRoot] = []
        for file in changed where file.size <= maxFileBytes {
            guard let all = parts(file.path) else { continue }
            // The longest base that contains the file (the game's folder can sit inside none of the others, but test it first).
            var best: (base: Base, count: Int)?
            for base in bases {
                guard let b = parts(base.path), all.count > b.count,
                      zip(b, all).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) else { continue }
                if best == nil || b.count > best!.count { best = (base, b.count) }
            }
            guard let found = best else { continue }
            let rest = Array(all[found.count...])
            if isNoise(rest, install: found.base.install) { continue }
            if rest.count == 1 {
                out.append(GameSaveRoot(path: file.path.replacingOccurrences(of: "\\", with: "/"), isFile: true, source: source))
                continue
            }
            let key = found.base.path.lowercased() + "/" + rest[0].lowercased()
            var group = groups[key] ?? (base: Array(all[..<found.count]).joined(separator: "/"), first: rest[0], files: [])
            group.files.append(rest)
            groups[key] = group
        }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            // The deepest folder all the group's files share (their folder parts, without the file name).
            var common = Array(group.files[0].dropLast())
            for file in group.files.dropFirst() {
                let folder = Array(file.dropLast())
                var n = 0
                while n < common.count, n < folder.count, common[n].caseInsensitiveCompare(folder[n]) == .orderedSame { n += 1 }
                common = Array(common[..<n])
            }
            if common.isEmpty { common = [group.first] }   // cannot happen (same first folder); keeps the root a folder
            if common.count > 2 { common = Array(common[..<2]) }
            out.append(GameSaveRoot(path: group.base + "/" + common.joined(separator: "/"), isFile: false, source: source))
        }
        return merge([], out)
    }

    /// `old` plus `new`, without a root that sits inside another (the broader one stays), sorted by path.
    static func merge(_ old: [GameSaveRoot], _ new: [GameSaveRoot]) -> [GameSaveRoot] {
        var all: [GameSaveRoot] = []
        for root in old + new {
            let key = root.path.lowercased()
            // The same place seen twice keeps the first one, with its source.
            if all.contains(where: { $0.path.lowercased() == key }) { continue }
            all.append(root)
        }
        func inside(_ inner: GameSaveRoot, _ outer: GameSaveRoot) -> Bool {
            !outer.isFile && inner.path.lowercased().hasPrefix(outer.path.lowercased() + "/")
        }
        let kept = all.filter { r in !all.contains(where: { $0 != r && inside(r, $0) }) }
        return kept.sorted { $0.path.lowercased() < $1.path.lowercased() }
    }

    /// What the player reads for a root: the Windows user's name never appears. "Documents › My Games › Foo",
    /// "AppData › Roaming › Vendor › Game", "Game folder › Save".
    static func display(_ root: GameSaveRoot, install: String? = nil) -> String {
        guard var list = parts(root.path) else { return root.path }
        if let install, let base = parts(install), list.count > base.count,
           zip(base, list).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) {
            return (["Game folder"] + list[base.count...]).joined(separator: " › ")
        }
        if list.count >= 3, list[0].lowercased() == "users" {
            if list[1].caseInsensitiveCompare("Public") == .orderedSame {
                list = ["Public"] + list[2...]
            } else {
                list = Array(list[2...])
            }
        }
        return list.joined(separator: " › ")
    }

    // MARK: Backups

    /// A name for the game's folder under Save Backups: the title without what a file name cannot hold.
    static func safeFolderName(_ title: String) -> String {
        let cleaned = String(title.map { "/\\:*?\"<>|\0".contains($0) ? "-" : $0 }.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Game" : cleaned
    }

    // Dates are made from numbers, never with a Foundation date formatter: those build an ICU date formatter, a call that
    // killed BCD itself in tester logs (BCDFormat's note in BCDStore.swift). The numbers are checked against Foundation's
    // calendar in tests/host/check-game-saves.py.

    struct Civil: Equatable {
        var year = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0
    }

    /// `date` as calendar numbers, `offset` seconds east of UTC.
    static func civil(_ date: Date, offset: Int) -> Civil {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e13 else { return Civil() }
        let whole = Int((seconds + Double(offset)).rounded(.down))
        let days = Int((Double(whole) / 86400).rounded(.down))
        let secondOfDay = whole - days * 86400
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        return Civil(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: doy - (153 * mp + 2) / 5 + 1,
                     hour: secondOfDay / 3600, minute: secondOfDay % 3600 / 60, second: secondOfDay % 60)
    }

    /// The moment calendar numbers name in a time zone that is `offset` seconds east of UTC.
    static func epoch(_ c: Civil, offset: Int) -> TimeInterval {
        let y = c.month <= 2 ? c.year - 1 : c.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = c.month > 2 ? c.month - 3 : c.month + 9
        let doy = (153 * mp + 2) / 5 + c.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return TimeInterval(days * 86400 + c.hour * 3600 + c.minute * 60 + c.second - offset)
    }

    private static func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    private static func stamp(_ date: Date, _ zone: TimeZone) -> String {
        let c = civil(date, offset: zone.secondsFromGMT(for: date))
        return "\(c.year)-\(two(c.month))-\(two(c.day)) \(two(c.hour)).\(two(c.minute)).\(two(c.second))"
    }

    /// "2026-10-25T14:32:07Z": for the note inside a backup.
    static func isoUTC(_ date: Date) -> String {
        let c = civil(date, offset: 0)
        return "\(c.year)-\(two(c.month))-\(two(c.day))T\(two(c.hour)):\(two(c.minute)):\(two(c.second))Z"
    }

    /// "2026-10-25 14.32.07 Manual.zip"; a name already taken gets " 2", " 3" and so on: a backup is never written over another.
    static func backupName(date: Date, kind: GameSaveKind, taken: Set<String> = [], timeZone: TimeZone = .current) -> String {
        let base = stamp(date, timeZone) + " " + kind.rawValue
        var name = base + ".zip"
        var n = 2
        while taken.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            name = base + " \(n).zip"
            n += 1
        }
        return name
    }

    /// The date and kind a backup's file name holds; nil for any other file.
    static func parseBackupName(_ name: String, timeZone: TimeZone = .current) -> (date: Date, kind: GameSaveKind)? {
        guard name.hasSuffix(".zip") else { return nil }
        let stem = String(name.dropLast(4))
        for kind in GameSaveKind.allCases {
            let marker = " " + kind.rawValue
            guard let r = stem.range(of: marker, options: .backwards) else { continue }
            let tail = stem[r.upperBound...]
            if !(tail.isEmpty || (tail.hasPrefix(" ") && Int(tail.dropFirst()) != nil)) { continue }
            // "2026-10-25 14.32.07": digits and the separators in their places, nothing else.
            let when = Array(stem[..<r.lowerBound])
            let shape = Array("dddd-dd-dd dd.dd.dd")
            guard when.count == shape.count else { continue }
            var ok = true
            for (c, want) in zip(when, shape) where want == "d" ? !c.isASCII || !c.isNumber : c != want { ok = false }
            guard ok else { continue }
            func number(_ from: Int, _ to: Int) -> Int { Int(String(when[from..<to])) ?? 0 }
            let c = Civil(year: number(0, 4), month: number(5, 7), day: number(8, 10), hour: number(11, 13), minute: number(14, 16), second: number(17, 19))
            guard (1...12).contains(c.month), (1...31).contains(c.day), c.hour < 24, c.minute < 60, c.second < 60 else { continue }
            // The zone's offset at that moment: guess with the local time as UTC, then correct once.
            let guess = epoch(c, offset: 0)
            let first = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: guess))
            let second = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: guess - Double(first)))
            return (Date(timeIntervalSince1970: epoch(c, offset: second)), kind)
        }
        return nil
    }

    /// Which backups the automatic rotation removes: the automatic ones beyond the `keep` newest. Manual backups and the
    /// copies made before a restore are never in the answer.
    static func toRemove(_ backups: [(name: String, date: Date, kind: GameSaveKind)], keep: Int) -> [String] {
        let keep = min(max(keep, keepRange.lowerBound), keepRange.upperBound)
        let automatic = backups.filter { $0.kind == .automatic }.sorted { $0.date > $1.date }
        return automatic.dropFirst(keep).map(\.name)
    }

    /// A fingerprint of a set of files (path, size, time): the same while nothing in them changed.
    static func signature(_ files: [GameSaveFile]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        for f in files.sorted(by: { $0.path.lowercased() < $1.path.lowercased() }) {
            mix(f.path.lowercased()); mix("|\(f.size)|\(Int64(f.modified))\n")
        }
        return String(format: "%016llx", h)
    }

    /// A line for the log: paths without the Windows user's name.
    static func logPath(_ path: String) -> String {
        guard var list = parts(path) else { return "?" }
        if list.count >= 2, list[0].lowercased() == "users", list[1].caseInsensitiveCompare("Public") != .orderedSame { list[1] = "<user>" }
        return list.joined(separator: "/")
    }
}
