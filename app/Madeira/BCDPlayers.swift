// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Players (round 604): which controller is Player 1, 2, 3 and 4 for the games, how hard each one rumbles, and which player the
// on-screen touch controls are. Games see up to four XInput pads; today a controller takes the first free slot as it connects, and
// the touch controls are always Player 1. This file is the rules, Foundation only; BCDPlayersLive.swift and GamepadInput carry
// them out.
//
// A person chooses a controller for a player by pressing a button on it ("Player 2: press a button on the controller"). What
// they chose is remembered by the controller's name and kind and its number among the same kind, so the same two identical
// pads come back in the same places while they connect in the same order. Nothing is remembered until they choose; with no
// choice every rule below gives exactly what the first free slot gave before.
//
// Global, not per game: it is about the controllers on the table, kept in the app's preferences (feature "players").

enum BCDPlayerSlots {
    static let count = 4

    /// The key a controller is remembered by: its name, its kind and its number among controllers of that name and kind
    /// (`ordinal`, counted in the order they are listed), so two identical pads are told apart by connection order.
    static func deviceKey(vendor: String, category: String, ordinal: Int) -> String {
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "/").trimmingCharacters(in: .whitespacesAndNewlines) }
        return [clean(vendor), clean(category), String(max(0, ordinal))].joined(separator: "|")
    }

    /// The slot a connecting controller takes: the first of its remembered slots that is free, else the first free slot, else none.
    static func choose(preferred: [Int], occupied: [Bool]) -> Int? {
        let slots = Array(0..<min(count, occupied.count))
        if let own = preferred.first(where: { slots.contains($0) && !occupied[$0] }) { return own }
        return slots.first { !occupied[$0] }
    }

    /// The remembered keys after a controller was put in `slot`: it appears in no other slot, and the controller that was in `slot`
    /// (if a different one) takes the slot the first one left, when it had one.
    static func assigning(_ assigned: [Int: String], key: String, to slot: Int, left: Int?, displaced: String?) -> [Int: String] {
        var out = assigned.filter { $0.value != key }
        out[slot] = key
        if let displaced, let left, left != slot {
            out = out.filter { $0.value != displaced }
            out[left] = displaced
        }
        return out
    }

    /// "Player 1" to "Player 4".
    static func title(_ slot: Int) -> String { "Player \(slot + 1)" }
}

struct BCDPlayerSettings: Equatable {
    /// Slot (0...3) -> the key of the controller remembered for it.
    var assigned: [Int: String] = [:]
    /// Slot -> how hard it rumbles, in percent; a slot with no entry rumbles in full.
    var rumble: [Int: Int] = [:]
    /// The slot the touch controls play as (0 is Player 1, as it has always been).
    var touchSlot = 0

    static let rumbleChoices = [100, 75, 50, 25, 0]
    static let lineNames: [String] = (1...BCDPlayerSlots.count).flatMap { ["p\($0)-pad", "p\($0)-rumble"] } + ["touch-player"]

    var isStandard: Bool { assigned.isEmpty && rumble.isEmpty && touchSlot == 0 }

    static func parse(_ get: (String) -> String?) -> BCDPlayerSettings {
        var s = BCDPlayerSettings()
        for n in 1...BCDPlayerSlots.count {
            if let key = get("p\(n)-pad")?.trimmingCharacters(in: .whitespaces), !key.isEmpty, key.contains("|") { s.assigned[n - 1] = key }
            if let text = get("p\(n)-rumble")?.trimmingCharacters(in: .whitespaces), let v = Int(text), rumbleChoices.contains(v), v != 100 { s.rumble[n - 1] = v }
        }
        if let text = get("touch-player")?.trimmingCharacters(in: .whitespaces), let v = Int(text), (1...BCDPlayerSlots.count).contains(v) { s.touchSlot = v - 1 }
        return s
    }

    func rumblePercent(_ slot: Int) -> Int { rumble[slot] ?? 100 }

    /// The factor on a slot's motors (0...1).
    func rumbleScale(_ slot: Int) -> Float { Float(rumblePercent(slot)) / 100 }

    /// The slots a controller was remembered for, lowest first.
    func preferredSlots(for key: String) -> [Int] { assigned.filter { $0.value == key }.keys.sorted() }

    /// The value of the `touch-player` line (empty for Player 1: the line is not kept).
    var touchLine: String { touchSlot == 0 ? "" : String(touchSlot + 1) }
}

// MARK: - What the screens show

struct BCDPlayerRow: Identifiable, Equatable {
    var slot: Int
    /// The controller in this slot, nil when none.
    var name: String?
    var rumble = 100
    var id: Int { slot }
    var title: String { BCDPlayerSlots.title(slot) }
}

/// What the players' card and the in-game menu do; BCDPlayersLive.swift carries it out on the engine.
@MainActor protocol BCDPlayersActions: AnyObject {
    /// "Press a button on the controller for Player N": the next controller whose button is pressed takes the slot.
    func beginAssign(slot: Int)
    func cancelAssign()
    func setRumble(slot: Int, percent: Int)
    func setTouchPlayer(slot: Int)
    /// Back to first-come first-served, full rumble, touch controls as Player 1.
    func reset()
}

/// The words the screens use for a rumble strength.
enum BCDPlayerWords {
    static func rumble(_ percent: Int) -> String { percent == 100 ? "Full" : percent == 0 ? "Off" : "\(percent)%" }
}

/// What the in-game menu's page reads (BCDInputMenu.swift): the card's model as plain values.
struct BCDPlayersSnapshot: Equatable {
    var rows: [BCDPlayerRow] = (0..<BCDPlayerSlots.count).map { BCDPlayerRow(slot: $0) }
    var listening: Int?
    var touchSlot = 0

    var connected: Int { rows.filter { $0.name != nil }.count }
}
