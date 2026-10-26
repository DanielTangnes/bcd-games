// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604): running a game's fixes (BCDSetupRules.swift has their lines and the places they may work in). Foundation
// only, so tests/host/check-game-setup.py compiles it on the Mac and runs it on a prefix built in a scratch folder.
//
// Every action is made to be run again with no further effect: an ini key already set is not written, a file that has the text is
// not written, a folder that is gone is not looked for. What an action replaces or takes away is kept: the first original of a
// file it changes goes to Documents/Fix Backups/<game>/original/, and a folder or file a delete takes goes to
// Documents/Fix Backups/<game>/deleted/ (the newest copy of each; the file system moves it, nothing is copied). Nothing in
// the game's own programs is touched: see BCDFixPaths.mayWriteFile and the binary check below.

// MARK: - ini text

/// An ini file as text: edits that keep everything else as it was (comments, order, spacing, line breaks, encoding).
enum BCDIniText {
    enum Encoding: Equatable { case utf8, utf8BOM, utf16LE, utf16BE, latin1 }

    /// The text of a file's bytes and how to write it back; nil when it is not a text file (a program, or binary data).
    static func decode(_ data: Data) -> (text: String, encoding: Encoding)? {
        if data.count > 4 << 20 { return nil }
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE {
            guard let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else { return nil }
            return (s, .utf16LE)
        }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            guard let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else { return nil }
            return (s, .utf16BE)
        }
        if b.count >= 2, b[0] == 0x4D, b[1] == 0x5A { return nil }   // "MZ": a program
        if data.prefix(8192).contains(0) { return nil }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            guard let s = String(data: data.dropFirst(3), encoding: .utf8) else { return nil }
            return (s, .utf8BOM)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        // Not UTF-8: the bytes stay as they are (ISO Latin 1 maps every byte to one character and back).
        return String(data: data, encoding: .isoLatin1).map { ($0, .latin1) }
    }

    static func encode(_ text: String, _ encoding: Encoding) -> Data? {
        switch encoding {
        case .utf8: return text.data(using: .utf8)
        case .utf8BOM: return text.data(using: .utf8).map { Data([0xEF, 0xBB, 0xBF]) + $0 }
        case .utf16LE: return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BE: return text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .latin1: return text.data(using: .isoLatin1)
        }
    }

    private struct Parsed {
        var lines: [String]
        var eol: String
        var finalBreak: Bool
    }

    private static func parse(_ text: String) -> Parsed {
        let crlf = text.contains("\r\n")
        let eol = crlf ? "\r\n" : (text.unicodeScalars.contains("\n") ? "\n" : "\r\n")
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        // A "\r\n" is one Character to Swift, so the last scalar is what tells.
        let final = text.isEmpty ? true : text.unicodeScalars.last == "\n"
        if lines.last == "" { lines.removeLast() }
        return Parsed(lines: lines, eol: eol, finalBreak: final)
    }

    private static func join(_ p: Parsed) -> String {
        p.lines.isEmpty ? "" : p.lines.joined(separator: p.eol) + (p.finalBreak ? p.eol : "")
    }

    private static func header(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), let close = t.lastIndex(of: "]") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// The lines of a section: the index after its header (or 0 for the part before any header) up to the next header.
    private static func range(of section: String, in lines: [String]) -> Range<Int>? {
        if section.isEmpty {
            let end = lines.firstIndex { header($0) != nil } ?? lines.count
            return 0..<end
        }
        guard let start = lines.firstIndex(where: { header($0)?.caseInsensitiveCompare(section) == .orderedSame }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { header($0) != nil } ?? lines.count
        return (start + 1)..<end
    }

    private static func keyLine(_ key: String, in lines: [String], _ range: Range<Int>) -> Int? {
        for i in range {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(";") || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            if t[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame { return i }
        }
        return nil
    }

    /// The value of the first line with that key in the section, or nil.
    static func value(of key: String, section: String, in text: String) -> String? {
        let p = parse(text)
        guard let r = range(of: section, in: p.lines), let i = keyLine(key, in: p.lines, r), let eq = p.lines[i].firstIndex(of: "=") else { return nil }
        return p.lines[i][p.lines[i].index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }

    /// `text` with the key set (the first line that has it is rewritten; a missing key goes to the end of its section, a
    /// missing section to the end of the file). Equal to `text` when the key already has the value.
    static func set(_ text: String, section: String, key: String, value: String) -> String {
        var p = parse(text)
        if let r = range(of: section, in: p.lines) {
            if let i = keyLine(key, in: p.lines, r), let eq = p.lines[i].firstIndex(of: "=") {
                let line = p.lines[i]
                let after = line[line.index(after: eq)...]
                let blanks = after.prefix { $0 == " " || $0 == "\t" }
                let current = after.dropFirst(blanks.count).trimmingCharacters(in: .whitespaces)
                if current == value { return text }
                p.lines[i] = String(line[...eq]) + blanks + value
            } else {
                // After the last line of the section that has something on it; the spacing follows the section's first key line.
                var at = r.upperBound
                while at > r.lowerBound, p.lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                var separator = "="
                if let sample = r.first(where: { let t = p.lines[$0].trimmingCharacters(in: .whitespaces); return !t.hasPrefix(";") && !t.hasPrefix("#") && t.contains("=") }),
                   let eq = p.lines[sample].firstIndex(of: "=") {
                    let before = p.lines[sample][..<eq]
                    let after = p.lines[sample][p.lines[sample].index(after: eq)...]
                    separator = (before.hasSuffix(" ") ? " " : "") + "=" + (after.hasPrefix(" ") ? " " : "")
                }
                p.lines.insert(key + separator + value, at: at)
            }
        } else {
            if let last = p.lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { p.lines.append("") }
            p.lines.append("[\(section)]")
            p.lines.append("\(key)=\(value)")
            p.finalBreak = true
        }
        return join(p)
    }

    /// `text` without the first line that has the key in the section; equal to `text` when there is none.
    static func remove(_ text: String, section: String, key: String) -> String {
        var p = parse(text)
        guard let r = range(of: section, in: p.lines), let i = keyLine(key, in: p.lines, r) else { return text }
        p.lines.remove(at: i)
        return join(p)
    }
}

// MARK: - Running fixes

enum BCDGameFixRunner {
    /// What a run needs.
    struct Setting {
        var drive: URL
        var context: BCDFixPaths.Context
        /// Documents/Fix Backups/<game>
        var backups: URL
        /// Reads one DLL out of a redistributable the game ships (BCDGameFixRedist.swift); nil: not available here.
        var extractMember: ((_ source: URL, _ member: String) throws -> Data)?
        var now: Date = Date()
    }

    struct Outcome: Equatable {
        /// One line for the log per fix that did something or could not.
        var lines: [String] = []
        /// Registry changes to make with the managed ones (BCDRegistryEdit.apply(permanent:)).
        var registry: [BCDRegistryEdit.Edit] = []
        var done = 0
        var unchanged = 0
        var failed = 0
    }

    /// Why a fix cannot run at all (a place that is not allowed), or nil.
    static func problem(_ fix: BCDGameFix, _ ctx: BCDFixPaths.Context) -> String? {
        func parts(_ path: String) -> [String]? { BCDFixPaths.resolve(path, ctx) }
        switch fix.action {
        case .ini(let path, _, _, _), .iniRemove(let path, _, _):
            guard let p = parts(path) else { return "the file's place is not one BCD can find (use %GAME%, %DOCUMENTS%, %APPDATA%, ... or C:\\...)" }
            return BCDFixPaths.mayWriteFile(p, ctx) ? nil : "BCD does not edit that place"
        case .write(let path, _, _):
            guard let p = parts(path) else { return "the file's place is not one BCD can find" }
            return BCDFixPaths.mayWriteFile(p, ctx) ? nil : "BCD does not write that place or a program"
        case .delete(let path):
            guard let p = parts(path) else { return "the place is not one BCD can find" }
            return BCDFixPaths.mayDelete(p, ctx) ? nil : "BCD takes aside only a file or folder inside the game's folder, a user's folders, ProgramData or Program Files"
        case .redist(let source, _, let destination, _):
            guard let s = parts(source), BCDFixPaths.zone(s, ctx) != nil else { return "the redistributable's place is not one BCD can find" }
            guard let d = parts(destination), BCDFixPaths.mayPlaceLibrary(d, ctx) else { return "a DLL goes only into the game's own folder" }
            return nil
        case .registry(let key, _, _), .registryDelete(let key, _):
            return BCDRegKey.parse(key) == nil ? "the registry key is not one BCD changes" : nil
        }
    }

    static func run(_ fixes: [BCDGameFix], _ setting: Setting) -> Outcome {
        var out = Outcome()
        for fix in fixes where fix.enabled {
            let label = "fix.\(fix.number) \(fix.action.kindWord)"
            if let why = problem(fix, setting.context) {
                out.lines.append("[game-fix] \(label): skipped, \(why)")
                out.failed += 1
                continue
            }
            do {
                let result = try perform(fix.action, setting, &out)
                switch result {
                case .changed(let words): out.lines.append("[game-fix] \(label): \(words)"); out.done += 1
                case .unchanged: out.unchanged += 1
                }
            } catch {
                out.lines.append("[game-fix] \(label): failed, \(error.localizedDescription)")
                out.failed += 1
            }
        }
        return out
    }

    private enum Result { case changed(String), unchanged }

    private struct FixError: LocalizedError {
        var text: String
        var errorDescription: String? { text }
        init(_ t: String) { text = t }
    }

    private static func url(_ path: String, _ s: Setting) throws -> URL {
        guard let parts = BCDFixPaths.resolve(path, s.context) else { throw FixError("the place is not valid") }
        return BCDFixPaths.onDisk(base: s.drive, parts: parts)
    }

    private static func flatName(_ file: URL, under drive: URL) -> String {
        let d = drive.resolvingSymlinksInPath().pathComponents, p = file.resolvingSymlinksInPath().pathComponents
        let rel = p.count > d.count ? Array(p[d.count...]) : [file.lastPathComponent]
        return rel.joined(separator: "__")
    }

    /// The first original of a file a fix changes, kept once.
    private static func keepOriginal(_ file: URL, _ s: Setting) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let folder = s.backups.appendingPathComponent("original", isDirectory: true)
        let target = folder.appendingPathComponent(flatName(file, under: s.drive))
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.copyItem(at: file, to: target)
    }

    private static func makeParent(of file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func writeAtomically(_ data: Data, to file: URL) throws {
        try makeParent(of: file)
        let part = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".bcd-part")
        try data.write(to: part)
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: part) }
        else { try FileManager.default.moveItem(at: part, to: file) }
    }

    private static func perform(_ action: BCDFixAction, _ s: Setting, _ out: inout Outcome) throws -> Result {
        let fm = FileManager.default
        switch action {
        case .ini(let path, let section, let key, let value):
            let file = try url(path, s)
            var text = "", encoding = BCDIniText.Encoding.utf8
            let existed = fm.fileExists(atPath: file.path)
            if existed {
                guard let data = try? Data(contentsOf: file), let decoded = BCDIniText.decode(data) else { throw FixError("\(file.lastPathComponent) is not a text file BCD edits") }
                text = decoded.text; encoding = decoded.encoding
            }
            let edited = BCDIniText.set(text, section: section, key: key, value: value)
            if existed && edited == text { return .unchanged }
            guard let data = BCDIniText.encode(edited, encoding) else { throw FixError("the text cannot be written in the file's encoding") }
            keepOriginal(file, s)
            try writeAtomically(data, to: file)
            return .changed("\(file.lastPathComponent): \(key) set" + (existed ? "" : " (file made)"))

        case .iniRemove(let path, let section, let key):
            let file = try url(path, s)
            guard fm.fileExists(atPath: file.path) else { return .unchanged }
            guard let data = try? Data(contentsOf: file), let decoded = BCDIniText.decode(data) else { throw FixError("\(file.lastPathComponent) is not a text file BCD edits") }
            let edited = BCDIniText.remove(decoded.text, section: section, key: key)
            if edited == decoded.text { return .unchanged }
            guard let bytes = BCDIniText.encode(edited, decoded.encoding) else { throw FixError("the text cannot be written in the file's encoding") }
            keepOriginal(file, s)
            try writeAtomically(bytes, to: file)
            return .changed("\(file.lastPathComponent): \(key) removed")

        case .write(let path, let replace, let text):
            let file = try url(path, s)
            let existed = fm.fileExists(atPath: file.path)
            if existed && !replace { return .unchanged }
            guard let data = text.data(using: .utf8) else { throw FixError("the text cannot be written") }
            if existed {
                guard let old = try? Data(contentsOf: file) else { throw FixError("\(file.lastPathComponent) cannot be read") }
                if old == data { return .unchanged }
                if old.prefix(2) == Data([0x4D, 0x5A]) { throw FixError("\(file.lastPathComponent) is a program") }
                keepOriginal(file, s)
            }
            try writeAtomically(data, to: file)
            return .changed("\(file.lastPathComponent) written")

        case .delete(let path):
            let file = try url(path, s)
            guard (try? fm.attributesOfItem(atPath: file.path)) != nil else { return .unchanged }
            let folder = s.backups.appendingPathComponent("deleted", isDirectory: true)
            let target = folder.appendingPathComponent(flatName(file, under: s.drive))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: file, to: target)
            return .changed("\(file.lastPathComponent) moved to Fix Backups")

        case .registry(let key, let name, let value):
            guard let k = BCDRegKey.parse(key) else { throw FixError("the registry key is not valid") }
            out.registry.append(BCDRegistryEdit.Edit(file: k.file, key: k.path, name: name, raw: value.regText))
            return .unchanged

        case .registryDelete(let key, let name):
            guard let k = BCDRegKey.parse(key) else { throw FixError("the registry key is not valid") }
            out.registry.append(BCDRegistryEdit.Edit(file: k.file, key: k.path, name: name, raw: nil))
            return .unchanged

        case .redist(let sourcePath, let member, let destination, let replace):
            let source = try url(sourcePath, s)
            guard fm.fileExists(atPath: source.path) else { throw FixError("\(source.lastPathComponent) is not there") }
            let asFolder = destination.hasSuffix("\\") || destination.hasSuffix("/")
            var target = try url(destination, s)
            var isDirectory: ObjCBool = false
            if asFolder || (fm.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                target = target.appendingPathComponent(member)
            }
            guard target.pathExtension.lowercased() == "dll" else { throw FixError("the destination is a folder or a .dll file") }
            if fm.fileExists(atPath: target.path) && !replace { return .unchanged }
            guard let extract = s.extractMember else { throw FixError("reading cabinets is not available here") }
            let data = try extract(source, member)
            guard data.count > 1024, data.count <= 64 << 20, data.prefix(2) == Data([0x4D, 0x5A]) else { throw FixError("\(member) is not a DLL") }
            if fm.fileExists(atPath: target.path) {
                if (try? Data(contentsOf: target)) == data { return .unchanged }
                keepOriginal(target, s)
            }
            try writeAtomically(data, to: target)
            return .changed("\(target.lastPathComponent) taken out of \(source.lastPathComponent)")
        }
    }
}
