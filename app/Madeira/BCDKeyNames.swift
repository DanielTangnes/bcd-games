// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The keys a person can name in round 604's settings (turbo keys, the radial menu's slots, a touch
// gesture's key): a short lower-case name for a Windows virtual-key code and back. Plain values,
// Foundation only. The names are what the settings store, so they never change once shipped.

enum BCDKeyNames {
    /// Name, virtual-key code, and the label shown on a key cap or in a list.
    static let table: [(name: String, vk: Int32, label: String)] = {
        var list: [(String, Int32, String)] = [
            ("esc", 0x1B, "Esc"), ("tab", 0x09, "Tab"), ("enter", 0x0D, "Enter"), ("space", 0x20, "Space"),
            ("backspace", 0x08, "Backspace"), ("shift", 0x10, "Shift"), ("ctrl", 0x11, "Ctrl"), ("alt", 0x12, "Alt"),
            ("up", 0x26, "Up arrow"), ("down", 0x28, "Down arrow"), ("left", 0x25, "Left arrow"), ("right", 0x27, "Right arrow"),
            ("del", 0x2E, "Delete"), ("ins", 0x2D, "Insert"), ("home", 0x24, "Home"), ("end", 0x23, "End"),
            ("pgup", 0x21, "Page up"), ("pgdn", 0x22, "Page down"), ("win", 0x5B, "Windows key"),
        ]
        for c in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let letter = String(UnicodeScalar(c)!)
            list.append((letter, Int32(UnicodeScalar(letter.uppercased())!.value), letter.uppercased()))
        }
        for d in 0...9 { list.append((String(d), Int32(0x30 + d), String(d))) }
        for n in 1...12 { list.append(("f\(n)", Int32(0x6F + n), "F\(n)")) }
        return list
    }()

    /// The key code of a name (any case, spaces around it ignored), nil for a name this table does not know.
    static func vk(_ name: String) -> Int32? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return table.first { $0.name == key }?.vk
    }

    static func name(_ vk: Int32) -> String? { table.first { $0.vk == vk }?.name }

    static func label(_ vk: Int32) -> String? { table.first { $0.vk == vk }?.label }

    /// "space, e, f" as key codes: unknown names are dropped, repeats too, and no more than `limit` are kept.
    static func parseList(_ text: String, limit: Int = 8) -> [Int32] {
        var out: [Int32] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            guard let vk = vk(String(part)), !out.contains(vk) else { continue }
            out.append(vk)
            if out.count == limit { break }
        }
        return out
    }

    /// The text `parseList` reads back to the same codes.
    static func listText(_ vks: [Int32]) -> String { vks.compactMap(name).joined(separator: ", ") }
}

extension BCDKeyNames {
    /// A short label for a key cap on a small button (the radial menu's ring): the arrows as arrows, long names cut short.
    static func cap(_ vk: Int32) -> String {
        switch vk {
        case 0x26: return "↑"
        case 0x28: return "↓"
        case 0x25: return "←"
        case 0x27: return "→"
        case 0x08: return "⌫"
        case 0x1B: return "Esc"
        case 0x2E: return "Del"
        case 0x2D: return "Ins"
        case 0x21: return "PgUp"
        case 0x22: return "PgDn"
        case 0x5B: return "Win"
        default: return label(vk) ?? "?"
        }
    }
}
