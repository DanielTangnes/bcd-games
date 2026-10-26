// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Things a person can ask BCD to do for the game with one touch (round 604): a key, a combination of keys, a mouse click or a turn of
// the wheel, BCD's own menu, the iOS keyboard, the key bar, or a short press of a controller button. The radial menu's slots and the
// touch gestures' bindings both name them, by a short text the settings store (`esc`, `alt+tab`, `mouse-right`, `pad-y`); the names
// never change once shipped. Plain values and rules, Foundation only: BCDInputActionRunner (BCDRadialLive.swift) carries them out.

enum BCDInputAction: Equatable {
    enum Mouse: String, CaseIterable {
        case left, right, middle
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() + " click" }
        var down: UInt32 { self == .left ? 0x2 : self == .right ? 0x8 : 0x20 }
        var up: UInt32 { self == .left ? 0x4 : self == .right ? 0x10 : 0x40 }
    }

    /// One key, down and up.
    case key(Int32)
    /// Modifiers held while a key is tapped (Alt+Tab).
    case chord([Int32], Int32)
    case click(Mouse)
    /// One notch of the wheel: +1 away from the player (up), -1 towards.
    case wheel(Int)
    /// BCD's in-game menu.
    case menu
    /// The iOS keyboard, shown or hidden.
    case keyboard
    /// The floating key bar, shown or hidden.
    case keyBar
    /// A short press of a button of player 1's controller.
    case pad(BCDPadInput)

    static let modifierNames: [String: Int32] = ["ctrl": 0x11, "alt": 0x12, "shift": 0x10, "win": 0x5B]
    static let modifierOrder = ["ctrl", "alt", "shift", "win"]

    /// The action a stored name means; nil for text this build does not know (the setting then does nothing).
    static func parse(_ text: String) -> BCDInputAction? {
        let id = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return nil }
        switch id {
        case "menu": return .menu
        case "keyboard": return .keyboard
        case "keybar": return .keyBar
        case "wheel-up": return .wheel(1)
        case "wheel-down": return .wheel(-1)
        default: break
        }
        if id.hasPrefix("mouse-"), let button = Mouse(rawValue: String(id.dropFirst(6))) { return .click(button) }
        if id.hasPrefix("pad-") {
            guard let input = BCDPadInput.named(String(id.dropFirst(4))) else { return nil }
            return .pad(input)
        }
        if id.contains("+") {
            var parts = id.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts.count <= 4, let key = BCDKeyNames.vk(parts.removeLast()) else { return nil }
            var mods: [Int32] = []
            for name in parts {
                guard let vk = modifierNames[name] else { return nil }
                if !mods.contains(vk) { mods.append(vk) }
            }
            guard !mods.isEmpty, !mods.contains(key) else { return nil }
            return .chord(mods, key)
        }
        return BCDKeyNames.vk(id).map(BCDInputAction.key)
    }

    /// The stored name (parse(id) gives the action back).
    var id: String {
        switch self {
        case .key(let vk): return BCDKeyNames.name(vk) ?? ""
        case .chord(let mods, let vk):
            let names = Self.modifierOrder.filter { name in mods.contains(Self.modifierNames[name] ?? -1) }
            return (names + [BCDKeyNames.name(vk) ?? ""]).joined(separator: "+")
        case .click(let button): return "mouse-" + button.rawValue
        case .wheel(let notches): return notches >= 0 ? "wheel-up" : "wheel-down"
        case .menu: return "menu"
        case .keyboard: return "keyboard"
        case .keyBar: return "keybar"
        case .pad(let input): return "pad-" + input.rawValue
        }
    }

    var title: String {
        switch self {
        case .key(let vk): return BCDKeyNames.label(vk) ?? "Key"
        case .chord(let mods, let vk):
            let names = Self.modifierOrder.filter { name in mods.contains(Self.modifierNames[name] ?? -1) }.map { $0 == "win" ? "Win" : $0.prefix(1).uppercased() + $0.dropFirst() }
            return (names + [BCDKeyNames.label(vk) ?? "Key"]).joined(separator: "+")
        case .click(let button): return button.title
        case .wheel(let notches): return notches >= 0 ? "Wheel up" : "Wheel down"
        case .menu: return "BCD menu"
        case .keyboard: return "iOS keyboard"
        case .keyBar: return "Key bar"
        case .pad(let input): return "Controller " + input.title
        }
    }

    /// A short label for a key cap on the radial menu's ring.
    var cap: String {
        switch self {
        case .key(let vk): return BCDKeyNames.cap(vk)
        case .chord(let mods, let vk):
            let lead = mods.compactMap { vk in Self.modifierNames.first { $0.value == vk }?.key.prefix(1).uppercased() }.joined()
            return lead + "+" + BCDKeyNames.cap(vk)
        case .click(let button): return button == .left ? "LMB" : button == .right ? "RMB" : "MMB"
        case .wheel(let notches): return notches >= 0 ? "▲" : "▼"
        case .menu: return "Menu"
        case .keyboard: return "Kbd"
        case .keyBar: return "Keys"
        case .pad(let input): return input.title
        }
    }

    // MARK: How it reaches the game

    /// The key presses of a key or a combination, with their timing (BCDExtraKeys decides it).
    var keySteps: [BCDKeyStep]? {
        switch self {
        case .key(let vk): return BCDExtraKeys.steps(.tap(vk))
        case .chord(let mods, let vk): return BCDExtraKeys.steps(.chord(mods, vk))
        default: return nil
        }
    }

    /// A click or a turn of the wheel as mouse events: (milliseconds after the start, SendInput flags, wheel data).
    var mouseSteps: [(delay: Int, flags: UInt32, data: Int32)]? {
        switch self {
        case .click(let button): return [(0, button.down, 0), (BCDExtraKeys.tapHold, button.up, 0)]
        case .wheel(let notches): return [(0, Self.wheelFlag, Int32(notches >= 0 ? 120 : -120))]
        default: return nil
        }
    }

    /// MOUSEEVENTF_WHEEL.
    static let wheelFlag: UInt32 = 0x0800

    // MARK: What a person can choose from

    struct Choice: Equatable {
        var id: String
        var title: String
        var group: String
    }

    /// Every action, grouped as a list shows them. Built once.
    static let choices: [Choice] = {
        var out: [Choice] = []
        func add(_ group: String, _ ids: [String]) {
            for id in ids { if let action = parse(id) { out.append(Choice(id: action.id, title: action.title, group: group)) } }
        }
        add("Keys", ["esc", "tab", "enter", "space", "backspace", "up", "down", "left", "right", "del", "ins", "home", "end", "pgup", "pgdn", "win", "shift", "ctrl", "alt"])
        add("Function keys", (1...12).map { "f\($0)" })
        add("Letters", "abcdefghijklmnopqrstuvwxyz".map(String.init))
        add("Numbers", (0...9).map(String.init))
        add("Combinations", ["alt+tab", "alt+enter", "ctrl+s", "ctrl+z", "ctrl+a", "ctrl+c", "ctrl+v", "shift+tab", "ctrl+tab"])
        add("Mouse", ["mouse-left", "mouse-right", "mouse-middle", "wheel-up", "wheel-down"])
        add("BCD", ["menu", "keyboard", "keybar"])
        add("Controller", BCDPadInput.allCases.map { "pad-" + $0.rawValue })
        return out
    }()
}
