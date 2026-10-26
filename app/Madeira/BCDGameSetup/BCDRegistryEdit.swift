// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604): changes to the prefix's registry, made in Wine's .reg text files before Wine starts (the way
// DockReset and WineProcessBridge's profile repair already work on them). Foundation only; it reads DockReset.RegText
// and adds to it, so tests/host/check-game-setup.py compiles DockReset.swift with this file.
//
// Only while no session runs: the wineserver keeps the registry in memory while one does and writes it back at the end,
// which would undo anything written here. BCD runs one Wine session per run of the app, and the launch hook that calls
// this runs before that session's wineserver exists.
//
// Two kinds of change:
//   * managed: the Windows version of a program, the Wine desktop's DPI and colours. A managed value belongs to BCD for as long
//     as the setting is on; when the setting goes (or another game is started), the value goes back to what it was: a state
//     file in the prefix (.bcd-setup-state.json) remembers what BCD wrote and what was there before. A value somebody else
//     (winecfg, a program) has changed since is left alone.
//   * permanent: a game fix's registry line. It sets or removes the value and nothing is remembered.
// Every file is written whole to a hidden name and moved into place, so a kill in the middle leaves the old file.

extension DockReset.RegText {
    /// The index range of a key's section (its header and the lines up to the next header); the first section of that path.
    func sectionRange(of path: String) -> Range<Int>? {
        let wanted = path.lowercased()
        return sections().first { $0.path == wanted }?.range
    }

    /// A value line's name ("" for the default value) and the text after the equals sign.
    static func valueParts(_ line: String) -> (name: String, raw: String)? {
        if line.hasPrefix("@=") { return ("", String(line.dropFirst(2))) }
        guard let parsed = value(line) else { return nil }
        return (parsed.name, String(parsed.raw))
    }

    /// The lines of a value inside a section: its line and the continuation lines (two blanks at the start) after a line that
    /// ends with a backslash.
    func valueLines(_ name: String, in range: Range<Int>) -> Range<Int>? {
        let wanted = name.lowercased()
        var index = range.lowerBound + 1
        while index < range.upperBound {
            var end = index + 1
            while end < range.upperBound, lines[end - 1].hasSuffix("\\"), lines[end].hasPrefix("  ") { end += 1 }
            if let parts = Self.valueParts(lines[index]), parts.name.lowercased() == wanted { return index..<end }
            index = end
        }
        return nil
    }

    /// The value as written (after the equals sign; continuation lines joined with a line break), or nil when absent.
    func rawValue(key: String, name: String) -> String? {
        guard let range = sectionRange(of: key), let at = valueLines(name, in: range) else { return nil }
        let first = Self.valueParts(lines[at.lowerBound])?.raw ?? ""
        return ([first] + lines[(at.lowerBound + 1)..<at.upperBound]).joined(separator: "\n")
    }

    enum Change: Equatable { case unchanged, added, replaced, removed }

    /// Sets a value to `raw` (the text after the equals sign, see BCDRegValue.regText). A key that is not there is made, at the
    /// end of the file, with the time `now`.
    @discardableResult
    mutating func setValue(key: String, name: String, raw: String, now: Date) -> Change {
        let nameText = BCDRegValue.nameText(name)
        let newLines = (nameText + "=" + raw).components(separatedBy: "\n")
        if let range = sectionRange(of: key) {
            if let at = valueLines(name, in: range) {
                if Array(lines[at]) == newLines { return .unchanged }
                lines.replaceSubrange(at, with: newLines)
                return .replaced
            }
            // After the header and the "#time=" style comment lines that follow it.
            var insert = range.lowerBound + 1
            while insert < range.upperBound, lines[insert].hasPrefix("#") { insert += 1 }
            lines.insert(contentsOf: newLines, at: insert)
            return .added
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let seconds = Int(now.timeIntervalSince1970)
        let filetime = (UInt64(seconds) + 11_644_473_600) * 10_000_000
        lines.append("")
        lines.append("[" + key.replacingOccurrences(of: "\\", with: "\\\\") + "] \(seconds)")
        lines.append("#time=" + BCDRegValue.hex(filetime, 1))
        lines += newLines
        lines.append("")
        return .added
    }

    /// Removes a value (and its continuation lines). A key left with no value at all is removed when `dropEmptyKey`.
    @discardableResult
    mutating func removeValue(key: String, name: String, dropEmptyKey: Bool = false) -> Change {
        guard let range = sectionRange(of: key), let at = valueLines(name, in: range) else { return .unchanged }
        lines.removeSubrange(at)
        if dropEmptyKey, let now = sectionRange(of: key) {
            let hasValue = lines[now].dropFirst().contains { $0.hasPrefix("\"") || $0.hasPrefix("@") }
            // The section runs up to the next header, so the blank line that separated it from the next goes with it.
            if !hasValue { lines.removeSubrange(now) }
        }
        return .removed
    }
}

enum BCDRegistryEdit {
    /// A change to one value. `raw` nil removes it.
    struct Edit: Equatable, Codable {
        var file: String        // "user.reg", "system.reg"
        var key: String         // single backslashes
        var name: String
        var raw: String?

        func same(slotOf other: Edit) -> Bool {
            file == other.file && key.lowercased() == other.key.lowercased() && name.lowercased() == other.name.lowercased()
        }
    }

    /// What BCD wrote for a managed setting and what was there before.
    struct Owned: Equatable, Codable {
        var edit: Edit
        var prior: String?
        var createdKey: Bool
    }

    struct State: Equatable, Codable {
        var owned: [Owned] = []
    }

    static let stateName = ".bcd-setup-state.json"
    static let maxFileBytes = 64 << 20

    /// What a pass did, for the log.
    struct Result: Equatable {
        var written: [String] = []        // files rewritten
        var changed = 0                   // values set, replaced or removed
        var retracted = 0                 // managed values put back
        var problems: [String] = []
    }

    /// Applies the managed values in `managed` (the complete list of what should be set now; owned values not in it go back),
    /// then the permanent edits, in `prefix` (the folder holding user.reg and system.reg). Does nothing, and touches no file,
    /// when there is nothing to set and nothing owned.
    @discardableResult
    static func apply(managed: [Edit], permanent: [Edit] = [], prefix: URL, now: Date = Date()) -> Result {
        var result = Result()
        let fm = FileManager.default
        let stateURL = prefix.appendingPathComponent(stateName)
        var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
        let stateBefore = state
        if managed.isEmpty, permanent.isEmpty, state.owned.isEmpty { return result }

        var files: [String: DockReset.RegText] = [:]
        var originals: [String: String] = [:]
        var dirty = Set<String>()
        func load(_ name: String) -> Bool {
            if files[name] != nil { return true }
            let url = prefix.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int else {
                result.problems.append("\(name) is not in the prefix")
                return false
            }
            guard size <= maxFileBytes, let text = try? String(contentsOf: url, encoding: .utf8) else {
                result.problems.append("\(name) cannot be read as text")
                return false
            }
            originals[name] = text
            files[name] = DockReset.RegText(text)
            return true
        }

        // 1. Managed values that are no longer wanted go back.
        var keep: [Owned] = []
        for owned in state.owned {
            if managed.contains(where: { $0.same(slotOf: owned.edit) }) { keep.append(owned); continue }
            guard load(owned.edit.file) else { keep.append(owned); continue }
            let current = files[owned.edit.file]!.rawValue(key: owned.edit.key, name: owned.edit.name)
            if current == owned.edit.raw {
                if let prior = owned.prior {
                    files[owned.edit.file]!.setValue(key: owned.edit.key, name: owned.edit.name, raw: prior, now: now)
                } else {
                    files[owned.edit.file]!.removeValue(key: owned.edit.key, name: owned.edit.name, dropEmptyKey: owned.createdKey)
                }
                dirty.insert(owned.edit.file)
                result.retracted += 1
            }
            // Changed by somebody else since: not ours any more, left as it is.
        }
        state.owned = keep

        // 2. Managed values that are wanted.
        for edit in managed {
            guard load(edit.file), let raw = edit.raw else { continue }
            let current = files[edit.file]!.rawValue(key: edit.key, name: edit.name)
            if let i = state.owned.firstIndex(where: { $0.edit.same(slotOf: edit) }) {
                if current == raw && state.owned[i].edit.raw == raw { continue }
                state.owned[i].edit.raw = raw
            } else {
                if current == raw { continue }   // already as wanted, by somebody else: not ours, nothing to give back
                let existed = files[edit.file]!.sectionRange(of: edit.key) != nil
                state.owned.append(Owned(edit: edit, prior: current, createdKey: !existed))
            }
            files[edit.file]!.setValue(key: edit.key, name: edit.name, raw: raw, now: now)
            dirty.insert(edit.file)
            result.changed += 1
        }

        // 3. Permanent edits.
        for edit in permanent {
            guard load(edit.file) else { continue }
            if let raw = edit.raw {
                if files[edit.file]!.setValue(key: edit.key, name: edit.name, raw: raw, now: now) != .unchanged { dirty.insert(edit.file); result.changed += 1 }
            } else if files[edit.file]!.removeValue(key: edit.key, name: edit.name) != .unchanged {
                dirty.insert(edit.file); result.changed += 1
            }
        }

        // 4. Write what changed, whole, to a hidden name first.
        for name in dirty.sorted() {
            guard let reg = files[name], reg.text != originals[name] else { continue }
            let url = prefix.appendingPathComponent(name)
            let part = prefix.appendingPathComponent("." + name + ".bcd-part")
            do {
                try reg.text.write(to: part, atomically: false, encoding: .utf8)
                _ = try fm.replaceItemAt(url, withItemAt: part)
                result.written.append(name)
            } catch {
                try? fm.removeItem(at: part)
                result.problems.append("\(name) could not be written: \(error.localizedDescription)")
            }
        }
        if state != stateBefore {
            if state.owned.isEmpty { try? fm.removeItem(at: stateURL) }
            else if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
        }
        return result
    }
}
