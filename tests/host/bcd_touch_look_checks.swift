// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-touch-look.py. That script compiles this file as main.swift together with
// app/Madeira/BCDTouchLook.swift (plain Foundation) and runs it: what a look's lines make, that BCD's own look is what a
// player who chose nothing has (and what the values were before round 604), every choice's colours and symbols.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}
func look(_ lines: [String: String]) -> BCDTouchLook { BCDTouchLook.parse { lines[$0] } }

require(look([:]) == BCDTouchLook() && look([:]).isStandard, "no lines: BCD's own look")
require(BCDTouchLook().body == .night && BCDTouchLook().accent == .violet && BCDTouchLook().icons == .xbox && BCDTouchLook().press == .glow, "... Night, BCD violet, Xbox letters, BCD light")
require(look(["look-body": "Graphite"]).body == .graphite && look(["look-body": " light "]).body == .light && look(["look-body": "clear"]).body == .clear, "body: any case, spaces around")
require(look(["look-accent": "green"]).accent == .green && look(["look-accent": "AMBER"]).accent == .amber, "accent")
require(look(["look-icons": "playstation"]).icons == .playstation && look(["look-icons": "PlayStation"]).icons == .playstation, "symbols")
require(look(["look-press": "ring"]).press == .ring && look(["look-press": "soft"]).press == .soft && look(["look-press": "solid"]).press == .solid, "press")
require(look(["look-body": "pink", "look-accent": "", "look-icons": "sega", "look-press": "?"]).isStandard, "anything this build does not know is BCD's own")
require(!look(["look-body": "graphite"]).isStandard && !look(["look-press": "soft"]).isStandard, "a changed choice is not the standard look")
require(BCDTouchLook.lineNames == ["look-body", "look-accent", "look-icons", "look-press"], "four lines")

// Every enum: the empty raw value is the default, raw values are unique, every choice has a title.
require(BCDTouchLook.Body.allCases.count == 4 && Set(BCDTouchLook.Body.allCases.map(\.rawValue)).count == 4 && BCDTouchLook.Body.night.rawValue == "", "bodies")
require(BCDTouchLook.Accent.allCases.count == 6 && Set(BCDTouchLook.Accent.allCases.map(\.rawValue)).count == 6 && BCDTouchLook.Accent.violet.rawValue == "", "accents")
require(BCDTouchLook.Icons.allCases.count == 2 && BCDTouchLook.Icons.xbox.rawValue == "", "symbol sets")
require(BCDTouchLook.Press.allCases.count == 4 && Set(BCDTouchLook.Press.allCases.map(\.rawValue)).count == 4 && BCDTouchLook.Press.glow.rawValue == "", "presses")
require(BCDTouchLook.Body.allCases.allSatisfy { !$0.title.isEmpty } && BCDTouchLook.Accent.allCases.allSatisfy { !$0.title.isEmpty }
        && BCDTouchLook.Icons.allCases.allSatisfy { !$0.title.isEmpty } && BCDTouchLook.Press.allCases.allSatisfy { !$0.title.isEmpty }, "every choice has words")
// Each choice round-trips through its raw value.
for body in BCDTouchLook.Body.allCases { require(look(["look-body": body.rawValue]).body == body, "body \(body.rawValue.isEmpty ? "night" : body.rawValue) reads back") }
for accent in BCDTouchLook.Accent.allCases { require(look(["look-accent": accent.rawValue]).accent == accent, "accent \(accent.rawValue.isEmpty ? "violet" : accent.rawValue) reads back") }
for icons in BCDTouchLook.Icons.allCases { require(look(["look-icons": icons.rawValue]).icons == icons, "symbols \(icons.rawValue.isEmpty ? "xbox" : icons.rawValue) read back") }
for press in BCDTouchLook.Press.allCases { require(look(["look-press": press.rawValue]).press == press, "press \(press.rawValue.isEmpty ? "glow" : press.rawValue) reads back") }

// BCD's own look keeps the numbers the controls always drew with.
require(BCDTouchLook().bodyColors == nil && BCDTouchLook().accent.ends == nil, "BCD's own look has no colours of its own: the views use BCDStyle's")
require(BCDTouchLook().fillStrength == 0.46 && BCDTouchLook().stickFillStrength == 0.36, "a button's fill 0.46 and a stick's 0.36, as before")
require(BCDTouchLook().glyph(pad: "A") == nil && BCDTouchLook().glyph(pad: "LB") == nil && BCDTouchLook().faceTint(pad: "A") == nil, "the Xbox set changes no face")
require(BCDTouchLook().summary == "BCD's own", "the summary says so")

// Other looks.
func unit(_ c: BCDTouchRGB) -> Bool { (0...1).contains(c.r) && (0...1).contains(c.g) && (0...1).contains(c.b) }
for body in BCDTouchLook.Body.allCases where body != .night {
    var l = BCDTouchLook(); l.body = body
    let c = l.bodyColors!
    require(unit(c.fill) && unit(c.rim) && unit(c.label), "\(body.rawValue): colours are in range")
    require(l.fillStrength > 0 && l.fillStrength < 1 && l.stickFillStrength > 0 && l.stickFillStrength < 1, "\(body.rawValue): fills are see-through")
}
require(look(["look-body": "clear"]).fillStrength < 0.1, "outline only: almost no fill")
require(look(["look-body": "light"]).bodyColors!.label.r < 0.3 && look(["look-body": "graphite"]).bodyColors!.label.r > 0.8, "a light body has a dark label, a dark one a light label")
for accent in BCDTouchLook.Accent.allCases where accent != .violet {
    let ends = accent.ends!
    require(unit(ends.0) && unit(ends.1) && ends.1.r + ends.1.g + ends.1.b >= ends.0.r + ends.0.g + ends.0.b, "\(accent.rawValue): two ends in range, the second the lighter")
}
let ps = look(["look-icons": "playstation"])
require(ps.glyph(pad: "A") == .symbol("xmark") && ps.glyph(pad: "B") == .symbol("circle") && ps.glyph(pad: "X") == .symbol("square") && ps.glyph(pad: "Y") == .symbol("triangle"),
        "PlayStation: cross, circle, square, triangle")
require(ps.glyph(pad: "LB") == .text("L1") && ps.glyph(pad: "RB") == .text("R1") && ps.glyph(pad: "LT") == .text("L2") && ps.glyph(pad: "RT") == .text("R2"), "... L1 R1 L2 R2")
require(ps.glyph(pad: "L3") == nil && ps.glyph(pad: "Menu") == nil && ps.glyph(pad: "D↑") == nil && ps.glyph(pad: "LS") == nil, "... everything else keeps its face")
require(ps.faceTint(pad: "A") != nil && ps.faceTint(pad: "Y") != nil && ps.faceTint(pad: "LB") == nil, "... the four symbols get their own colours")
require(Set(["A", "B", "X", "Y"].map { "\(ps.faceTint(pad: $0)!)" }).count == 4, "... four different ones")
require(!look(["look-body": "graphite", "look-accent": "blue"]).summary.isEmpty && look(["look-body": "graphite"]).summary != "BCD's own", "a chosen look has its own summary")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
