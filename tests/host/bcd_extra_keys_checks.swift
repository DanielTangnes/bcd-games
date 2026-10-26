// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-extra-keys.py. That script compiles this file as main.swift
// together with app/Madeira/BCDExtraKeys.swift (plain Foundation) and runs it: which key code every extra key
// sends, in which order and how long it is held, and how a latched modifier behaves.

import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

func codes(_ steps: [BCDKeyStep]) -> String {
    steps.map { "\($0.delay)ms \($0.down ? "v" : "^")\(String($0.vk, radix: 16))" }.joined(separator: " ")
}

// ---- the keys ----------------------------------------------------------------------------------
let ids = BCDExtraKeys.all.map(\.id)
require(Set(ids).count == ids.count, "every key has its own id")
require(BCDExtraKeys.barIDs.allSatisfy { BCDExtraKeys.key($0) != nil }, "every id on the floating bar is a key")
require(BCDExtraKeys.keyboardPageIDs.allSatisfy { BCDExtraKeys.key($0) != nil }, "every id on the keyboard bar's second page is a key")
require(Set(BCDExtraKeys.barIDs).count == BCDExtraKeys.barIDs.count, "no key twice on the floating bar")
require(Set(BCDExtraKeys.keyboardPageIDs).count == BCDExtraKeys.keyboardPageIDs.count, "no key twice on the second page")
for must in ["ctrl", "alt", "shift", "esc", "alt-tab", "alt-enter", "win", "del"] + (1...12).map({ "f\($0)" }) {
    require(BCDExtraKeys.barIDs.contains(must), "the floating bar has \(must)")
    require(BCDExtraKeys.keyboardPageIDs.contains(must) || ["esc"].contains(must),
            "the keyboard bar's second page has \(must) (Esc is on its first page)")
}

let expected: [String: Int32] = [
    "esc": 0x1B, "tab": 0x09, "enter": 0x0D, "space": 0x20, "del": 0x2E, "ins": 0x2D, "win": 0x5B,
    "home": 0x24, "end": 0x23, "pgup": 0x21, "pgdn": 0x22, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
]
for (id, vk) in expected.sorted(by: { $0.key < $1.key }) {
    require(BCDExtraKeys.key(id)?.action == .tap(vk), "\(id) is virtual key 0x\(String(vk, radix: 16))")
}
for n in 1...12 {
    require(BCDExtraKeys.key("f\(n)")?.action == .tap(0x6F + Int32(n)), "F\(n) is virtual key 0x\(String(0x6F + Int32(n), radix: 16))")
}
require(BCDExtraKeys.key("ctrl")?.action == .modifier(0x11) && BCDExtraKeys.key("alt")?.action == .modifier(0x12)
        && BCDExtraKeys.key("shift")?.action == .modifier(0x10), "Ctrl, Alt and Shift are the modifiers 0x11, 0x12 and 0x10")
require(BCDExtraKeys.key("alt-tab")?.action == .chord([0x12], 0x09), "Alt+Tab is Alt with Tab")
require(BCDExtraKeys.key("alt-enter")?.action == .chord([0x12], 0x0D), "Alt+Enter is Alt with Enter")
require(BCDExtraKeys.all.filter(\.isModifier).count == 3, "three modifiers, no more")

// ---- how a key reaches the game ----------------------------------------------------------------
require(codes(BCDExtraKeys.steps(.tap(0x74))) == "0ms v74 70ms ^74", "a tap: down, held 70 ms, up: \(codes(BCDExtraKeys.steps(.tap(0x74))))")
let altTab = BCDExtraKeys.steps(.chord([0x12], 0x09))
require(codes(altTab) == "0ms v12 30ms v9 100ms ^9 130ms ^12", "Alt+Tab: Alt down, Tab after 30 ms, held 70 ms, Alt up 30 ms later: \(codes(altTab))")
let altTabHeld = BCDExtraKeys.steps(.chord([0x12], 0x09), held: [0x12])
require(codes(altTabHeld) == "0ms v9 70ms ^9", "Alt+Tab with Alt already held leaves Alt alone: \(codes(altTabHeld))")
let two = BCDExtraKeys.steps(.chord([0x11, 0x12], 0x2E))
require(codes(two) == "0ms v11 0ms v12 30ms v2e 100ms ^2e 130ms ^12 130ms ^11", "a two-modifier chord lets go in reverse: \(codes(two))")
require(BCDExtraKeys.steps(.modifier(0x11)).isEmpty, "a modifier has no steps of its own")

// Every down meets its up, in every action, and no step is earlier than the one before it.
for key in BCDExtraKeys.all where !key.isModifier {
    for held in [Set<Int32>(), [0x11], [0x12], [0x10, 0x11]] {
        let steps = BCDExtraKeys.steps(key.action, held: held)
        var down: [Int32: Int] = [:]
        for s in steps { down[s.vk, default: 0] += s.down ? 1 : -1 }
        require(down.values.allSatisfy { $0 == 0 }, "\(key.id) with \(held.sorted()) held: every down has its up")
        require(zip(steps, steps.dropFirst()).allSatisfy { $0.delay <= $1.delay }, "\(key.id) with \(held.sorted()) held: in time order")
        require(!steps.contains { held.contains($0.vk) }, "\(key.id) with \(held.sorted()) held: a held modifier is not pressed again")
    }
}

// ---- the latches ---------------------------------------------------------------------------------
var latches = BCDModifierLatches()
require(latches.isEmpty && latches.held.isEmpty, "no latch at the start")
require(codes(latches.tap(0x11)) == "0ms v11" && latches.states[0x11] == .once, "a tap holds Ctrl for one key")
require(codes(latches.tap(0x11)) == "0ms ^11" && latches.isEmpty, "a second tap lets it go")
require(codes(latches.longPress(0x12)) == "0ms v12" && latches.states[0x12] == .locked, "a long press locks Alt")
require(codes(latches.longPress(0x12)) == "0ms ^12" && latches.isEmpty, "a second long press lets it go")
_ = latches.tap(0x11)
require(latches.longPress(0x11).isEmpty && latches.states[0x11] == .locked, "a long press on a held one locks it without a second down")
require(codes(latches.tap(0x11)) == "0ms ^11" && latches.isEmpty, "a tap on a locked one lets it go")

_ = latches.tap(0x11)          // once
_ = latches.longPress(0x10)    // locked
let after = latches.keyPressed(after: 100)
require(codes(after) == "100ms ^11", "after a key the one-key Ctrl goes up when the key's steps end: \(codes(after))")
require(latches.states == [0x10: .locked], "... and the locked Shift stays")
require(latches.keyPressed(after: 10).isEmpty, "a key with nothing one-key held sends no release")
require(codes(latches.releaseAll()) == "0ms ^10" && latches.isEmpty, "release all lets the locked one go")
require(latches.releaseAll().isEmpty, "release all twice sends nothing the second time")

// Ctrl held for one key, then F5: Ctrl is down before F5 and up after it.
var ctrl = BCDModifierLatches()
var posts = ctrl.tap(0x11)
let f5 = BCDExtraKeys.steps(.tap(0x74), held: ctrl.held)
posts += f5 + ctrl.keyPressed(after: BCDModifierLatches.duration(f5) + BCDExtraKeys.modifierTail)
require(codes(posts) == "0ms v11 0ms v74 70ms ^74 100ms ^11", "Ctrl then F5: \(codes(posts))")
require(BCDModifierLatches.duration(f5) == 70, "a tap takes 70 ms")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures != 0 { exit(1) }
