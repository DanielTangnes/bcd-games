// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604), the rules, with nothing of the engine in them. Foundation only and pure
// (tests/host/check-game-setup.py compiles this file on the Mac and runs it): how a line of a game's own file names a
// game fix, which places of the prefix a fix may touch, the Windows versions Wine knows, and the text a registry value
// takes in Wine's .reg files.
//
// A game fix is one line of the game's own file (GameProfiles.swift, the file the game page's "Game config" shows):
//
//     fix.1 = ini "%DOCUMENTS%\My Games\Foo\foo.ini" "Display" "FullScreen" "1"
//     fix.2 = reg "HKCU\Software\Foo" "Intro" dword 0
//     fix.3 = delete "%LOCALAPPDATA%\Foo\ShaderCache"
//     fix.4 = write "%GAME%\autoexec.cfg" missing "bind x quit\n"
//     fix.5 = redist "%GAME%\redist\dx.cab" "xinput1_3.dll" "%GAME%\"
//
// Words are separated by blanks; a word with blanks is in double quotes, and a double quote inside quotes is written twice.
// Backslashes are plain characters (they are Windows paths), except in the text of a write, where \n \t \r and \\ are escapes.
// `fix-off.N` is the same line switched off. The fixes run in the order of their numbers at every start of the game,
// before Wine starts, and each one is made so that running it again changes nothing. A fix that cannot run is logged
// and skipped; it never stops the game from starting.
//
// What a fix can never do: change a program. No fix writes a file with an executable extension, edits a file that
// starts with "MZ", or deletes a program; the redist action alone writes a DLL, and only into the game's own folder.
// Nothing outside drive_c is reachable, nothing in C:\windows (BCD links it again at every start), and no fix deletes
// a whole profile, program-files or game folder (it needs a place below one).

// MARK: - Words

enum BCDSetupText {
    /// The words of a line: blanks separate them, double quotes group (the quotes go), and inside quotes two double quotes make
    /// one. Backslashes mean nothing here. nil for a quote left open or a NUL.
    static func words(_ line: String) -> [String]? {
        var out: [String] = []
        var word = ""
        var started = false
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\0" { return nil }
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { word.append("\""); i += 1 } else { quoted = false }
                } else { word.append(c) }
            } else if c == "\"" { quoted = true; started = true }
            else if c == " " || c == "\t" {
                if started || !word.isEmpty { out.append(word) }
                word = ""; started = false
            } else { word.append(c) }
            i += 1
        }
        if quoted { return nil }
        if started || !word.isEmpty { out.append(word) }
        return out
    }

    /// A word as `words` reads it back: bare when it has nothing special, else in quotes (a quote inside is doubled).
    static func quote(_ word: String) -> String {
        let plain = !word.isEmpty && !word.contains(where: { " \t\"".contains($0) })
        if plain { return word }
        return "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The text of a write as the file gets it: \n, \r, \t and \\ are the line break, return, tab and backslash; any other
    /// backslash stays (C:\Games is C:\Games).
    static func decodeText(_ text: String) -> String {
        var out = ""
        var escaping = false
        for c in text {
            if escaping {
                switch c {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(c)
                }
                escaping = false
            } else if c == "\\" { escaping = true }
            else { out.append(c) }
        }
        if escaping { out.append("\\") }
        return out
    }

    /// The other way: a text with line breaks as one line.
    static func encodeText(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}

// MARK: - Registry values

/// A registry value as the setup writes it.
enum BCDRegValue: Equatable {
    case string(String)
    case dword(UInt32)
    case expandString(String)
    case binary([UInt8])

    /// The text after `"name"=` in Wine's .reg files.
    var regText: String {
        switch self {
        case .string(let s): return Self.quoted(s)
        case .dword(let n): return "dword:" + Self.hex(UInt64(n), 8)
        case .expandString(let s): return "str(2):" + Self.quoted(s)
        case .binary(let bytes): return "hex:" + bytes.map { Self.hex(UInt64($0), 2) }.joined(separator: ",")
        }
    }

    static func hex(_ n: UInt64, _ width: Int) -> String {
        let s = String(n, radix: 16)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// Wine's string syntax: \\ and \" escaped, anything outside printable ASCII as \xNNNN (one per UTF-16 unit).
    static func quoted(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(UInt8(unit))))
            default: out += "\\x" + hex(UInt64(unit), 4)
            }
        }
        return out + "\""
    }

    /// `"name"=` with the same escaping for a value name.
    static func nameText(_ name: String) -> String { name.isEmpty ? "@" : quoted(name) }
}

/// A registry key as a fix names it: "HKCU\Software\Foo" or "HKLM\Software\Wow6432Node\Foo".
struct BCDRegKey: Equatable {
    enum Hive: String { case user, machine }
    var hive: Hive
    /// The key below the hive, single backslashes ("Software\Foo").
    var path: String

    /// The .reg file that holds the hive in a prefix.
    var file: String { hive == .user ? "user.reg" : "system.reg" }

    static func parse(_ text: String) -> BCDRegKey? {
        var parts = text.replacingOccurrences(of: "/", with: "\\").split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let hive: Hive
        switch parts.removeFirst().uppercased() {
        case "HKCU", "HKEY_CURRENT_USER": hive = .user
        case "HKLM", "HKEY_LOCAL_MACHINE": hive = .machine
        default: return nil
        }
        guard !parts.contains(where: { $0.isEmpty || $0.contains("\0") || $0.contains("\n") || $0.contains("\r") || $0.utf8.count > 255 }),
              parts.count <= 24 else { return nil }
        // HKLM\System is the services, drivers and hardware profile of the prefix: a game has no business there.
        if hive == .machine, parts[0].caseInsensitiveCompare("System") == .orderedSame { return nil }
        return BCDRegKey(hive: hive, path: parts.joined(separator: "\\"))
    }
}

// MARK: - Windows versions

/// The Windows versions a game can be told it runs on: Wine's own names (dlls/ntdll/version.c), read from
/// HKCU\Software\Wine\AppDefaults\<program>\Version at each program's start. Wine's default, which a prefix with no
/// entry answers, is Windows 10.
enum BCDWindowsVersion {
    struct Entry: Equatable {
        /// What the game's file holds ("win7"); "" is Wine's default.
        var id: String
        var label: String
        /// The value Wine reads. Windows XP is its own 64-bit version for a 64-bit program.
        var wine: String
        var wine64: String? = nil
    }

    static let all: [Entry] = [
        Entry(id: "", label: "Windows 10 (BCD's default)", wine: "win10"),
        Entry(id: "win11", label: "Windows 11", wine: "win11"),
        Entry(id: "win81", label: "Windows 8.1", wine: "win81"),
        Entry(id: "win8", label: "Windows 8", wine: "win8"),
        Entry(id: "win7", label: "Windows 7", wine: "win7"),
        Entry(id: "vista", label: "Windows Vista", wine: "vista"),
        Entry(id: "winxp", label: "Windows XP", wine: "winxp", wine64: "winxp64"),
        Entry(id: "win2k", label: "Windows 2000", wine: "win2k"),
        Entry(id: "winme", label: "Windows Me", wine: "winme"),
        Entry(id: "win98", label: "Windows 98", wine: "win98"),
        Entry(id: "win95", label: "Windows 95", wine: "win95"),
        Entry(id: "nt40", label: "Windows NT 4.0", wine: "nt40"),
    ]

    static let key = "win.version"

    static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// The value for a program of the given width; nil for the default and for an id Wine's list here does not hold.
    static func registryValue(_ id: String, is64Bit: Bool) -> String? {
        guard !id.isEmpty, let e = entry(id) else { return nil }
        return is64Bit ? (e.wine64 ?? e.wine) : e.wine
    }

    /// The registry key a program's version lives in.
    static func appKey(program: String) -> String { "Software\\Wine\\AppDefaults\\" + program }

    /// A program name fit for a key: a plain file name ending in .exe (no folder, no control characters).
    static func isProgramName(_ name: String) -> Bool {
        guard name.lowercased().hasSuffix(".exe"), name.utf8.count <= 128 else { return false }
        return !name.contains(where: { "\\/:*?\"<>|\0\r\n".contains($0) })
    }
}

// MARK: - Where a fix may work

enum BCDFixPaths {
    /// What a fix needs to know about the prefix and the game.
    struct Context: Equatable {
        /// The Windows users' folders below drive_c/users (names as on disk), "Public" included.
        var users: [String]
        /// The game's folder, relative to drive_c with "/" ("Program Files (x86)/Steam/steamapps/common/Foo"); nil: it has none.
        var install: String?

        /// The user whose folders %DOCUMENTS% and the like mean: the first that is not Public, in name order.
        var user: String? { users.filter { $0.caseInsensitiveCompare("Public") != .orderedSame }.sorted().first }
    }

    /// Components of an absolute or %TOKEN% path as parts under drive_c; nil when it names no place a fix can use.
    static func resolve(_ text: String, _ ctx: Context) -> [String]? {
        var rest = text.replacingOccurrences(of: "/", with: "\\")
        var base: [String]
        if rest.hasPrefix("%"), let close = rest.dropFirst().firstIndex(of: "%") {
            let token = String(rest[rest.index(after: rest.startIndex)..<close]).uppercased()
            rest = String(rest[rest.index(after: close)...])
            switch token {
            case "GAME":
                guard let install = ctx.install, let parts = split(install) else { return nil }
                base = parts
            case "DOCUMENTS", "SAVEDGAMES", "APPDATA", "LOCALAPPDATA", "LOCALLOW", "USER", "DESKTOP":
                guard let user = ctx.user else { return nil }
                let sub: [String]
                switch token {
                case "DOCUMENTS": sub = ["Documents"]
                case "SAVEDGAMES": sub = ["Saved Games"]
                case "APPDATA": sub = ["AppData", "Roaming"]
                case "LOCALAPPDATA": sub = ["AppData", "Local"]
                case "LOCALLOW": sub = ["AppData", "LocalLow"]
                case "DESKTOP": sub = ["Desktop"]
                default: sub = []
                }
                base = ["users", user] + sub
            case "PUBLIC": base = ["users", "Public"]
            case "PROGRAMDATA": base = ["ProgramData"]
            case "PROGRAMFILES": base = ["Program Files"]
            case "PROGRAMFILESX86": base = ["Program Files (x86)"]
            default: return nil
            }
            if !rest.isEmpty && !rest.hasPrefix("\\") { return nil }
        } else if rest.count >= 3, rest.prefix(3).uppercased() == "C:\\" {
            base = []
            rest = String(rest.dropFirst(3))
        } else {
            return nil
        }
        let tail = rest.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        let parts = base + tail
        guard !parts.isEmpty, parts.count <= 40,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("\0") || $0.contains(":") || $0.contains("\n")
                                        || $0.contains("\r") || $0.utf8.count > 255 }) else { return nil }
        return parts
    }

    private static func split(_ path: String) -> [String]? {
        let list = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !list.isEmpty, !list.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return list
    }

    /// The Windows users' folder names under drive_c/users (not Public), in name order.
    static func users(drive: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: drive.appendingPathComponent("users").path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.caseInsensitiveCompare("Public") != .orderedSame }.sorted()
    }

    /// Follows `parts` below `base` the way Wine does: without regard to case, the given spelling for what does not exist.
    static func onDisk(base: URL, parts: [String]) -> URL {
        var url = base
        for (index, part) in parts.enumerated() {
            let isFolder = index < parts.count - 1
            let exact = url.appendingPathComponent(part, isDirectory: isFolder)
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                url = url.appendingPathComponent(match, isDirectory: isFolder)
            } else {
                url = exact
            }
        }
        return url
    }

    /// The part of the prefix a path is in, and how many components it is below that part's root.
    enum Zone: Equatable {
        case game(below: Int)
        case user(below: Int)
        case programData(below: Int)
        case programFiles(below: Int)
        case publicFiles(below: Int)

        var depth: Int {
            switch self {
            case .game(let n), .user(let n), .programData(let n), .programFiles(let n), .publicFiles(let n): return n
            }
        }
        var isGame: Bool { if case .game = self { return true }; return false }
    }

    private static func under(_ parts: [String], _ root: [String]) -> Int? {
        guard parts.count >= root.count,
              zip(root, parts).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }) else { return nil }
        return parts.count - root.count
    }

    /// nil: nothing a fix may touch (C:\windows, drive_c itself, another top folder, the users' own top folders).
    static func zone(_ parts: [String], _ ctx: Context) -> Zone? {
        guard let first = parts.first?.lowercased(), first != "external" else { return nil }   // an external drive's games: no fix touches them
        if let install = ctx.install, let root = split(install), let n = under(parts, root) { return .game(below: n) }
        switch first {
        case "windows": return nil
        case "programdata": return .programData(below: parts.count - 1)
        case "program files", "program files (x86)": return .programFiles(below: parts.count - 1)
        case "users":
            guard parts.count >= 3 else { return nil }
            // users/<name>/<folder>/...: below counts from the profile's folders (Documents, AppData\Roaming, ...), not from the profile.
            if parts[1].caseInsensitiveCompare("Public") == .orderedSame { return .publicFiles(below: parts.count - 3) }
            let sub = parts[2].lowercased()
            if sub == "appdata" {
                guard parts.count >= 4 else { return nil }
                return .user(below: parts.count - 4)
            }
            return .user(below: parts.count - 3)
        default: return nil
        }
    }

    /// Extensions of programs and libraries: the fixes that write or edit files never work on these (the redist action's DLL
    /// is its own, narrower case).
    static let programExtensions: Set<String> = [
        "exe", "dll", "sys", "ocx", "scr", "drv", "cpl", "com", "msi", "msp", "ax", "efi", "so", "dylib", "bat", "cmd", "ps1", "vbs", "js",
    ]

    static func isProgramFile(_ name: String) -> Bool {
        programExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A path a text fix (ini, write) may write: in a zone, with a file name that is not a program's.
    static func mayWriteFile(_ parts: [String], _ ctx: Context) -> Bool {
        guard let zone = zone(parts, ctx), let name = parts.last, !isProgramFile(name) else { return false }
        // A file straight in a Windows user's profile, in AppData's top folders, or in a program-files root is not a game's.
        return zone.depth >= 1
    }

    /// A path a delete may take: a file or folder strictly below a place, never a program.
    static func mayDelete(_ parts: [String], _ ctx: Context) -> Bool {
        guard let zone = zone(parts, ctx), let name = parts.last, !isProgramFile(name) else { return false }
        return zone.depth >= 1
    }

    /// Where a redist DLL goes: a folder or file inside the game's own folder.
    static func mayPlaceLibrary(_ parts: [String], _ ctx: Context) -> Bool {
        guard let zone = zone(parts, ctx) else { return false }
        return zone.isGame && zone.depth >= 0
    }
}

// MARK: - Game fixes

enum BCDFixAction: Equatable {
    case ini(path: String, section: String, key: String, value: String)
    case iniRemove(path: String, section: String, key: String)
    case registry(key: String, name: String, value: BCDRegValue)
    case registryDelete(key: String, name: String)
    case delete(path: String)
    case write(path: String, replace: Bool, text: String)
    case redist(source: String, member: String, destination: String, replace: Bool)

    var kindWord: String {
        switch self {
        case .ini: return "ini"
        case .iniRemove: return "ini-remove"
        case .registry: return "reg"
        case .registryDelete: return "reg-delete"
        case .delete: return "delete"
        case .write: return "write"
        case .redist: return "redist"
        }
    }

    /// The line's value as it goes into the game's file.
    var line: String {
        let q = BCDSetupText.quote
        switch self {
        case .ini(let path, let section, let key, let value):
            return "ini \(q(path)) \(q(section)) \(q(key)) \(q(value))"
        case .iniRemove(let path, let section, let key):
            return "ini-remove \(q(path)) \(q(section)) \(q(key))"
        case .registry(let key, let name, let value):
            switch value {
            case .string(let s): return "reg \(q(key)) \(q(name)) sz \(q(s))"
            case .dword(let n): return "reg \(q(key)) \(q(name)) dword \(n)"
            case .expandString(let s): return "reg \(q(key)) \(q(name)) expand \(q(s))"
            case .binary(let b): return "reg \(q(key)) \(q(name)) binary \(q(b.map { BCDRegValue.hex(UInt64($0), 2) }.joined(separator: " ")))"
            }
        case .registryDelete(let key, let name):
            return "reg-delete \(q(key)) \(q(name))"
        case .delete(let path):
            return "delete \(q(path))"
        case .write(let path, let replace, let text):
            return "write \(q(path)) \(replace ? "always" : "missing") \(q(BCDSetupText.encodeText(text)))"
        case .redist(let source, let member, let destination, let replace):
            return "redist \(q(source)) \(q(member)) \(q(destination))" + (replace ? " replace" : "")
        }
    }

    /// One line for the page and the log: what the fix does, in words.
    var summary: String {
        switch self {
        case .ini(let path, let section, let key, let value):
            return "In \(Self.file(path)), \(section.isEmpty ? "" : "[\(section)] ")\(key) = \(value)"
        case .iniRemove(let path, _, let key):
            return "In \(Self.file(path)), remove \(key)"
        case .registry(let key, let name, let value):
            return "Registry: \(key) › \(name.isEmpty ? "(default)" : name) = \(Self.valueWords(value))"
        case .registryDelete(let key, let name):
            return "Registry: remove \(key) › \(name.isEmpty ? "(default)" : name)"
        case .delete(let path):
            return "Move \(Self.file(path)) aside"
        case .write(let path, let replace, _):
            return (replace ? "Write " : "Write, if missing, ") + Self.file(path)
        case .redist(_, let member, let destination, _):
            return "Take \(member) out of the game's redistributable into \(Self.file(destination))"
        }
    }

    private static func file(_ path: String) -> String {
        let last = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").last.map(String.init) ?? path
        return last
    }

    private static func valueWords(_ v: BCDRegValue) -> String {
        switch v {
        case .string(let s), .expandString(let s): return "\"\(s)\""
        case .dword(let n): return String(n)
        case .binary(let b): return "\(b.count) bytes"
        }
    }

    /// The action a line's value names, or why it names none.
    static func parse(_ value: String) -> (action: BCDFixAction?, error: String?) {
        guard let w = BCDSetupText.words(value), let kind = w.first?.lowercased() else { return (nil, "the line cannot be read (check the quotes)") }
        let a = Array(w.dropFirst())
        func bad(_ text: String) -> (BCDFixAction?, String?) { (nil, text) }
        switch kind {
        case "ini":
            guard a.count == 4 else { return bad("ini takes a file, a section, a key and a value") }
            guard !a[2].isEmpty, !a[2].contains(where: { "=\n\r".contains($0) }), !a[1].contains(where: { "[]\n\r".contains($0) }),
                  !a[3].contains(where: { "\n\r".contains($0) }) else { return bad("the section, key or value has a character an ini file cannot hold") }
            return (.ini(path: a[0], section: a[1], key: a[2], value: a[3]), nil)
        case "ini-remove":
            guard a.count == 3 else { return bad("ini-remove takes a file, a section and a key") }
            guard !a[2].isEmpty, !a[2].contains(where: { "=\n\r".contains($0) }), !a[1].contains(where: { "[]\n\r".contains($0) }) else {
                return bad("the section or key has a character an ini file cannot hold")
            }
            return (.iniRemove(path: a[0], section: a[1], key: a[2]), nil)
        case "reg":
            guard a.count == 4 else { return bad("reg takes a key, a value name, a type (sz, dword, expand, binary) and the data") }
            guard BCDRegKey.parse(a[0]) != nil else { return bad("the registry key must start with HKCU or HKLM (HKLM\\System is not available)") }
            guard !a[1].contains(where: { "\n\r\0".contains($0) }) else { return bad("the value name has a character the registry file cannot hold") }
            switch a[2].lowercased() {
            case "sz": return (.registry(key: a[0], name: a[1], value: .string(a[3])), nil)
            case "expand": return (.registry(key: a[0], name: a[1], value: .expandString(a[3])), nil)
            case "dword":
                let text = a[3].lowercased()
                let n = text.hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
                guard let n else { return bad("dword takes a whole number up to 4294967295 (or 0x..)") }
                return (.registry(key: a[0], name: a[1], value: .dword(n)), nil)
            case "binary":
                let pairs = a[3].split(whereSeparator: { " ,".contains($0) })
                let bytes = pairs.compactMap { $0.count <= 2 ? UInt8($0, radix: 16) : nil }
                guard bytes.count == pairs.count, bytes.count <= 4096 else { return bad("binary takes up to 4096 bytes as hex pairs") }
                return (.registry(key: a[0], name: a[1], value: .binary(bytes)), nil)
            default: return bad("the registry type is sz, dword, expand or binary")
            }
        case "reg-delete":
            guard a.count == 2 else { return bad("reg-delete takes a key and a value name") }
            guard BCDRegKey.parse(a[0]) != nil else { return bad("the registry key must start with HKCU or HKLM (HKLM\\System is not available)") }
            return (.registryDelete(key: a[0], name: a[1]), nil)
        case "delete":
            guard a.count == 1 else { return bad("delete takes one path") }
            return (.delete(path: a[0]), nil)
        case "write":
            guard a.count == 3, ["always", "missing"].contains(a[1].lowercased()) else { return bad("write takes a file, always or missing, and the text") }
            guard a[2].utf8.count <= 65_536 else { return bad("the text is over 64 KB") }
            return (.write(path: a[0], replace: a[1].lowercased() == "always", text: BCDSetupText.decodeText(a[2])), nil)
        case "redist":
            guard a.count == 3 || (a.count == 4 && a[3].lowercased() == "replace") else {
                return bad("redist takes a .cab or .zip (or a program holding cabinets), the DLL's name and the folder or file to put it in")
            }
            guard a[1].lowercased().hasSuffix(".dll"), !a[1].contains(where: { "\\/".contains($0) }) else { return bad("the member is the name of a DLL") }
            return (.redist(source: a[0], member: a[1], destination: a[2], replace: a.count == 4), nil)
        default:
            return bad("\"\(kind)\" is not a fix this build knows (ini, ini-remove, reg, reg-delete, delete, write, redist)")
        }
    }
}

struct BCDGameFix: Equatable, Identifiable {
    var number: Int
    var enabled: Bool
    var action: BCDFixAction
    var id: Int { number }
}

enum BCDGameFixes {
    static let onPrefix = "fix."
    static let offPrefix = "fix-off."
    static let maxFixes = 40

    /// The fixes in a game's file (its values), in number order, and a message for every line that names none.
    static func list(_ values: [String: String]) -> (fixes: [BCDGameFix], problems: [String]) {
        var fixes: [BCDGameFix] = []
        var problems: [String] = []
        for (key, value) in values {
            let enabled = key.hasPrefix(onPrefix)
            guard enabled || key.hasPrefix(offPrefix) else { continue }
            let tail = key.dropFirst(enabled ? onPrefix.count : offPrefix.count)
            guard let number = Int(tail), number >= 1, number <= 999 else { problems.append("\(key): the number after the dot is 1 to 999"); continue }
            let parsed = BCDFixAction.parse(value)
            if let action = parsed.action { fixes.append(BCDGameFix(number: number, enabled: enabled, action: action)) }
            else { problems.append("\(key): \(parsed.error ?? "not understood")") }
        }
        // The same number on and off: the one that is on wins, and the number is listed once.
        var seen = Set<Int>()
        let sorted = fixes.sorted { $0.number != $1.number ? $0.number < $1.number : ($0.enabled && !$1.enabled) }
        fixes = sorted.filter { seen.insert($0.number).inserted }
        return (fixes, problems.sorted())
    }

    /// The first free number for a new fix.
    static func nextNumber(_ values: [String: String]) -> Int {
        let used = Set(values.keys.compactMap { key -> Int? in
            if key.hasPrefix(onPrefix) { return Int(key.dropFirst(onPrefix.count)) }
            if key.hasPrefix(offPrefix) { return Int(key.dropFirst(offPrefix.count)) }
            return nil
        })
        return (1...999).first { !used.contains($0) } ?? 999
    }

    static func key(_ number: Int, enabled: Bool) -> String { (enabled ? onPrefix : offPrefix) + String(number) }
}
