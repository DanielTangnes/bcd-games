// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The extra keys (round 603): the keys a game wants that the iOS keyboard does not have and a
// touch layout rarely binds. Alt+Tab, Alt+Enter, Win, F1 to F12, Esc, Del, Ins, Home, End, Page
// Up and Down, and Ctrl, Alt and Shift as latches. Two places show them: a floating key bar over
// the game (BCDExtraKeyBar.swift, opened from the in-game menu) and a second page on the bar over
// the iOS keyboard (BCDKeyboardBar in BCDSession.swift, behind its "Fn" key).
//
// This file is plain values and rules, no engine type: what a key presses, in which order and
// how long, and how a latched modifier behaves. BCDExtraKeysLive.swift posts them, through the
// same winios_post_key every other key of the app uses. Nothing runs until a key is pressed.

/// Windows virtual-key codes the extra keys use.
enum BCDVK {
    static let back: Int32 = 0x08, tab: Int32 = 0x09, enter: Int32 = 0x0D
    static let shift: Int32 = 0x10, ctrl: Int32 = 0x11, alt: Int32 = 0x12
    static let escape: Int32 = 0x1B, space: Int32 = 0x20
    static let pageUp: Int32 = 0x21, pageDown: Int32 = 0x22, end: Int32 = 0x23, home: Int32 = 0x24
    static let left: Int32 = 0x25, up: Int32 = 0x26, right: Int32 = 0x27, down: Int32 = 0x28
    static let insert: Int32 = 0x2D, delete: Int32 = 0x2E
    static let leftWin: Int32 = 0x5B
    static let f1: Int32 = 0x70

    static let modifiers: Set<Int32> = [shift, ctrl, alt]
}

/// What pressing an extra key does.
enum BCDExtraKeyAction: Equatable {
    /// One key, down then up.
    case tap(Int32)
    /// Modifiers down, the key down and up, the modifiers up again (Alt+Tab).
    case chord([Int32], Int32)
    /// Ctrl, Alt or Shift: stays down until it is let go (BCDModifierLatches).
    case modifier(Int32)
}

/// One key of the bar.
struct BCDExtraKey: Identifiable, Equatable {
    var id: String
    var title: String
    var action: BCDExtraKeyAction
    /// What VoiceOver says when the title is a symbol or a short form.
    var spoken: String? = nil

    var isModifier: Bool {
        if case .modifier = action { return true }
        return false
    }

    /// The modifier's key code, nil for any other key.
    var modifierCode: Int32? {
        if case .modifier(let code) = action { return code }
        return nil
    }
}

/// One post to the game: a key down or up, `delay` milliseconds after the press started.
struct BCDKeyStep: Equatable {
    var delay: Int
    var vk: Int32
    var down: Bool
}

enum BCDExtraKeys {
    /// Every key, by id.
    static let all: [BCDExtraKey] = {
        var keys: [BCDExtraKey] = [
            .init(id: "ctrl", title: "Ctrl", action: .modifier(BCDVK.ctrl)),
            .init(id: "alt", title: "Alt", action: .modifier(BCDVK.alt)),
            .init(id: "shift", title: "Shift", action: .modifier(BCDVK.shift)),
            .init(id: "esc", title: "Esc", action: .tap(BCDVK.escape), spoken: "Escape"),
            .init(id: "tab", title: "Tab", action: .tap(BCDVK.tab)),
            .init(id: "enter", title: "Enter", action: .tap(BCDVK.enter)),
            .init(id: "space", title: "Space", action: .tap(BCDVK.space)),
            .init(id: "del", title: "Del", action: .tap(BCDVK.delete), spoken: "Delete"),
            .init(id: "ins", title: "Ins", action: .tap(BCDVK.insert), spoken: "Insert"),
            .init(id: "win", title: "Win", action: .tap(BCDVK.leftWin), spoken: "Windows key"),
            .init(id: "alt-tab", title: "Alt+Tab", action: .chord([BCDVK.alt], BCDVK.tab)),
            .init(id: "alt-enter", title: "Alt+Enter", action: .chord([BCDVK.alt], BCDVK.enter)),
            .init(id: "home", title: "Home", action: .tap(BCDVK.home)),
            .init(id: "end", title: "End", action: .tap(BCDVK.end)),
            .init(id: "pgup", title: "PgUp", action: .tap(BCDVK.pageUp), spoken: "Page up"),
            .init(id: "pgdn", title: "PgDn", action: .tap(BCDVK.pageDown), spoken: "Page down"),
            .init(id: "left", title: "←", action: .tap(BCDVK.left), spoken: "Left arrow"),
            .init(id: "up", title: "↑", action: .tap(BCDVK.up), spoken: "Up arrow"),
            .init(id: "down", title: "↓", action: .tap(BCDVK.down), spoken: "Down arrow"),
            .init(id: "right", title: "→", action: .tap(BCDVK.right), spoken: "Right arrow"),
        ]
        for n in 1...12 { keys.append(.init(id: "f\(n)", title: "F\(n)", action: .tap(BCDVK.f1 + Int32(n - 1)))) }
        return keys
    }()

    static func key(_ id: String) -> BCDExtraKey? { all.first { $0.id == id } }

    /// The floating bar, left to right: the latches, then the keys a game asks for most.
    static let barIDs: [String] = ["ctrl", "alt", "shift", "esc", "tab", "enter", "alt-tab", "alt-enter", "win", "del"]
        + (1...12).map { "f\($0)" }
        + ["space", "ins", "home", "end", "pgup", "pgdn", "left", "up", "down", "right"]

    /// The second page of the bar over the iOS keyboard (its first page keeps Esc, Ctrl, Shift, Alt,
    /// Tab, Enter and the arrows as it always had them): the latches again, so Ctrl+F5 needs no
    /// flipping back, then what the keyboard lacks.
    static let keyboardPageIDs: [String] = ["ctrl", "shift", "alt", "win", "alt-tab", "alt-enter", "del", "ins", "home", "end", "pgup", "pgdn"]
        + (1...12).map { "f\($0)" }

    static var bar: [BCDExtraKey] { barIDs.compactMap(key) }
    static var keyboardPage: [BCDExtraKey] { keyboardPageIDs.compactMap(key) }

    // MARK: How a key reaches the game

    /// A key is held for this long (milliseconds) between its down and its up, a modifier for this
    /// long before and after it. A game that polls the keyboard once a frame sees a press of one
    /// frame at 60 FPS and a little more; a down and an up in the same millisecond can fall
    /// between two looks.
    static let tapHold = 70, modifierLead = 30, modifierTail = 30

    /// The posts for an action, in order. `held` holds the modifiers that are already down (a
    /// latch): a chord leaves those alone, so the game never sees one go up under a latch.
    /// A `.modifier` action has no steps of its own; BCDModifierLatches decides them.
    static func steps(_ action: BCDExtraKeyAction, held: Set<Int32> = []) -> [BCDKeyStep] {
        switch action {
        case .tap(let vk):
            return [BCDKeyStep(delay: 0, vk: vk, down: true), BCDKeyStep(delay: tapHold, vk: vk, down: false)]
        case .chord(let modifiers, let vk):
            let pressed = modifiers.filter { !held.contains($0) }
            var out: [BCDKeyStep] = pressed.map { BCDKeyStep(delay: 0, vk: $0, down: true) }
            let at = pressed.isEmpty ? 0 : modifierLead
            out.append(BCDKeyStep(delay: at, vk: vk, down: true))
            out.append(BCDKeyStep(delay: at + tapHold, vk: vk, down: false))
            let tail = at + tapHold + (pressed.isEmpty ? 0 : modifierTail)
            out += pressed.reversed().map { BCDKeyStep(delay: tail, vk: $0, down: false) }
            return out
        case .modifier:
            return []
        }
    }
}

/// The modifiers the bar holds down for the game. Tapping one holds it for the next key only; a
/// long press locks it until it is tapped again. A modifier that is down is posted as down at
/// once, so the game sees Ctrl held while a key follows.
struct BCDModifierLatches: Equatable {
    enum State: Equatable { case once, locked }

    private(set) var states: [Int32: State] = [:]

    /// The modifiers that are down now.
    var held: Set<Int32> { Set(states.keys) }
    var isEmpty: Bool { states.isEmpty }

    /// A tap on a modifier: off holds it for one key, held (either way) lets it go.
    mutating func tap(_ vk: Int32) -> [BCDKeyStep] {
        if states[vk] != nil {
            states[vk] = nil
            return [BCDKeyStep(delay: 0, vk: vk, down: false)]
        }
        states[vk] = .once
        return [BCDKeyStep(delay: 0, vk: vk, down: true)]
    }

    /// A long press: locks it (already down for a key: no second down), or lets a locked one go.
    mutating func longPress(_ vk: Int32) -> [BCDKeyStep] {
        switch states[vk] {
        case .locked?:
            states[vk] = nil
            return [BCDKeyStep(delay: 0, vk: vk, down: false)]
        case .once?:
            states[vk] = .locked
            return []
        case nil:
            states[vk] = .locked
            return [BCDKeyStep(delay: 0, vk: vk, down: true)]
        }
    }

    /// After a key other than a modifier went to the game: the one-key modifiers let go, `after`
    /// milliseconds in (the end of the key's own steps, so the key still sees them).
    mutating func keyPressed(after: Int) -> [BCDKeyStep] {
        let once = states.filter { $0.value == .once }.map(\.key).sorted()
        for vk in once { states[vk] = nil }
        return once.map { BCDKeyStep(delay: after, vk: $0, down: false) }
    }

    /// Everything down is let go (the bar closes, the menu opens, the app leaves the foreground).
    mutating func releaseAll() -> [BCDKeyStep] {
        let all = states.keys.sorted()
        states.removeAll()
        return all.map { BCDKeyStep(delay: 0, vk: $0, down: false) }
    }

    /// How long a key's steps take (when the one-key modifiers may go up).
    static func duration(_ steps: [BCDKeyStep]) -> Int { steps.map(\.delay).max() ?? 0 }
}
