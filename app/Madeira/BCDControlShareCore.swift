// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Shareable control layouts (round 604, C11). A layout (BCD's named touch layouts: Settings › Controls, the in-game menu) can be saved as a small
// file and sent to someone, and a file like that can be added as a new layout. The file is JSON with one envelope around the layout's own controls:
//
//     { "bcdControls": 1, "name": "Hollow Knight keys", "game": "Hollow Knight", "app": "604",
//       "controls": [ { "id": "...", "nx": 0.12, "ny": 0.7, "scale": 1.2, "action": { "pad": { "_0": "A" } } }, ... ] }
//
// The controls are exactly what the app keeps for them (TouchControl, encoded by the app's own encoder), so a field a later build adds travels
// with them and an older build refuses what it cannot read instead of dropping it. What comes in from outside is data, never instructions:
// this file checks the envelope and each control's shape, sizes and ranges before the app's decoder sees anything (the decoder is the second
// gate), caps the file at 256 KB and a layout at 120 controls, makes the name safe, and gives every control a fresh id. Nothing is run, no
// address is opened, no file is written outside the app's own layout list. Foundation only: tests/host/check-bcd-control-share.py compiles it.
// The live side is BCDControlShareLive.swift; Settings › Controls has the two rows.

enum BCDControlShare {
    static let formatKey = "bcdControls"
    static let version = 1
    static let maxBytes = 256 * 1024
    static let maxControls = 120
    static let maxNameLength = 40
    static let maxGameLength = 80
    static let maxStringLength = 64
    static let maxDepth = 5
    static let fileSuffix = ".bcd-controls.json"

    enum Problem: Error, Equatable {
        case tooBig, notJSON, notALayoutFile, newerVersion(Int), noControls, tooMany(Int), badControl(Int, String)

        var words: String {
            switch self {
            case .tooBig: return "That file is too big to be a layout (the most is \(BCDControlShare.maxBytes / 1024) KB)."
            case .notJSON: return "That file is not a BCD layout: it could not be read."
            case .notALayoutFile: return "That file is not a BCD layout."
            case .newerVersion(let v): return "That layout was made by a newer BCD (format \(v)). Update BCD to read it."
            case .noControls: return "That layout has no controls."
            case .tooMany(let n): return "That layout has \(n) controls; BCD reads at most \(BCDControlShare.maxControls)."
            case .badControl(let i, let why): return "Control \(i + 1) of that layout is not valid (\(why))."
            }
        }
    }

    /// What a good file holds, ready for the app's decoder.
    struct Parsed: Equatable {
        var name: String
        var game: String?
        /// The controls as JSON (an array), each with a fresh id (a control's id keys its touch state: two layouts must not share them).
        var controlsJSON: Data
        var count: Int
    }

    // MARK: Text

    /// A name for a layout or a game: control characters out, one line, trimmed, at most `limit` characters; never empty (`fallback`).
    static func cleanName(_ text: String, limit: Int = maxNameLength, fallback: String = "Shared layout") -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { out.append(" ") }
            else if scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format { out.append(scalar) }
        }
        let flat = String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let cut = String(String.UnicodeScalarView(flat.unicodeScalars.prefix(limit))).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? fallback : cut
    }

    /// A file name for sharing: letters, digits, spaces, dashes and dots only.
    static func fileName(for name: String) -> String {
        let safe = String(String.UnicodeScalarView(cleanName(name).unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "_" ? scalar : "-"
        }))
        return safe.trimmingCharacters(in: CharacterSet(charactersIn: " .-")).isEmpty ? "layout" + fileSuffix : safe + fileSuffix
    }

    /// The name an imported layout is saved under: its own, unless a layout of that name exists (a built-in's or the player's), then
    /// "Name (2)", "Name (3)"... Comparison ignores case and surrounding space, as the store's does.
    static func importName(_ proposed: String, taken: [String]) -> String {
        let base = cleanName(proposed)
        let lower = Set(taken.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if !lower.contains(base.lowercased()) { return base }
        var n = 2
        while true {
            let suffix = " (\(n))"
            let name = String(base.prefix(maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
            if !lower.contains(name.lowercased()) { return name }
            n += 1
        }
    }

    // MARK: Writing

    /// The file for a layout whose controls the app encoded to `controlsJSON` (a JSON array).
    static func export(name: String, game: String?, build: String, controlsJSON: Data) throws -> Data {
        guard let controls = try JSONSerialization.jsonObject(with: controlsJSON) as? [Any] else { throw Problem.noControls }
        var envelope: [String: Any] = [formatKey: version, "name": cleanName(name), "app": String(build.prefix(20)), "controls": controls]
        if let game, !game.isEmpty { envelope["game"] = cleanName(game, limit: maxGameLength, fallback: "") }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maxBytes else { throw Problem.tooBig }
        return data
    }

    // MARK: Reading

    static func parse(_ data: Data) -> Result<Parsed, Problem> {
        guard data.count <= maxBytes else { return .failure(.tooBig) }
        guard let any = try? JSONSerialization.jsonObject(with: data), let root = any as? [String: Any] else { return .failure(.notJSON) }
        guard let versionNumber = root[formatKey] as? NSNumber else { return .failure(.notALayoutFile) }
        guard versionNumber.intValue <= version else { return .failure(.newerVersion(versionNumber.intValue)) }
        guard versionNumber.intValue >= 1, let list = root["controls"] as? [Any] else { return .failure(.notALayoutFile) }
        guard !list.isEmpty else { return .failure(.noControls) }
        guard list.count <= maxControls else { return .failure(.tooMany(list.count)) }
        var cleaned: [[String: Any]] = []
        for (i, item) in list.enumerated() {
            guard var control = item as? [String: Any] else { return .failure(.badControl(i, "not an object")) }
            if let why = problem(in: control) { return .failure(.badControl(i, why)) }
            control["id"] = UUID().uuidString
            cleaned.append(control)
        }
        guard let json = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) else { return .failure(.notJSON) }
        let name = cleanName((root["name"] as? String) ?? "")
        let game = (root["game"] as? String).map { cleanName($0, limit: maxGameLength, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 }
        return .success(Parsed(name: name, game: game, controlsJSON: json, count: cleaned.count))
    }

    /// Why a control is not valid, or nil. Position and size are numbers in range (the app clamps them again on load), the action is
    /// present, no text is long, nothing is nested deeper than a control needs.
    static func problem(in control: [String: Any]) -> String? {
        for key in ["nx", "ny"] {
            guard let number = control[key] as? NSNumber, !isBool(number) else { return "\(key) is not a number" }
            let v = number.doubleValue
            guard v.isFinite, v >= -0.5, v <= 1.5 else { return "\(key) is out of range" }
        }
        guard let scale = control["scale"] as? NSNumber, !isBool(scale) else { return "scale is not a number" }
        guard scale.doubleValue.isFinite, scale.doubleValue > 0, scale.doubleValue <= 10 else { return "scale is out of range" }
        guard control["action"] != nil else { return "no action" }
        return shape(control, depth: 0)
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func shape(_ value: Any, depth: Int) -> String? {
        if depth > maxDepth { return "nested too deep" }
        switch value {
        case let s as String:
            return s.unicodeScalars.count > maxStringLength ? "a text is too long" : nil
        case let d as [String: Any]:
            if d.count > 24 { return "too many fields" }
            for (k, v) in d {
                if k.unicodeScalars.count > maxStringLength { return "a field name is too long" }
                if let why = shape(v, depth: depth + 1) { return why }
            }
            return nil
        case let a as [Any]:
            if a.count > 16 { return "a list is too long" }
            for v in a { if let why = shape(v, depth: depth + 1) { return why } }
            return nil
        case is NSNumber:
            return (value as? NSNumber).map { $0.doubleValue.isFinite } == true ? nil : "a number is not finite"
        case is NSNull:
            return nil
        default:
            return "an unexpected value"
        }
    }

    /// What the player is told after a good import.
    static func added(_ parsed: Parsed, as name: String) -> String {
        "Added \u{201C}\(name)\u{201D}, \(parsed.count) control\(parsed.count == 1 ? "" : "s")" + (parsed.game.map { ", made for \($0)" } ?? "")
            + ". It is in the layout list; your own layouts are unchanged."
    }
}
