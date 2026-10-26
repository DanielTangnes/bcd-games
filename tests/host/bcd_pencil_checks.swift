// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-pencil.py. That script compiles this file as main.swift together with
// app/Madeira/BCDPencil.swift (plain Foundation) and runs it: the settings a game's lines make, and the pointer events a Pencil's
// touches, hovers, squeezes and double taps make.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}
func pencil(_ lines: [String: String]) -> BCDPencilSettings { BCDPencilSettings.parse { lines[$0] } }

require(pencil([:]) == BCDPencilSettings() && !pencil([:]).isOn && pencil([:]).tap == .right, "no lines: off, a squeeze is a right click")
require(pencil(["pencil": "1"]).isOn && !pencil(["pencil": "0"]).isOn && !pencil(["pencil": "yes"]).isOn, "pencil: only 1")
require(pencil(["pencil-tap": "middle"]).tap == .middle && pencil(["pencil-tap": "none"]).tap == .none && pencil(["pencil-tap": "x"]).tap == .right, "the squeeze's choices")
require(BCDPencilSettings.lineNames == ["pencil", "pencil-tap"] && BCDPencilSettings.Tap.allCases.allSatisfy { !$0.title.isEmpty }, "two lines, words for each choice")

var p = BCDPencilPointer()
require(p.hovered(x: 10, y: 20) == [.move(10, 20)], "hovering moves the pointer")
require(p.hovered(x: 10, y: 20) == [], "... once for the same place")
require(p.hovered(x: 11, y: 20) == [.move(11, 20)], "... and again when it moves")
require(p.touchBegan(x: 50, y: 60) == [.move(50, 60), .leftDown(50, 60)] && p.down, "the nib on the glass: the pointer goes there and the button goes down")
require(p.touchMoved(x: 51, y: 61) == [.move(51, 61)] && p.touchMoved(x: 51, y: 61) == [], "moving on the glass is a drag, once for each place")
require(p.hovered(x: 99, y: 99) == [], "a hover while it touches is nothing")
require(p.touchEnded(x: 52, y: 62) == [.leftUp(52, 62)] && !p.down, "lifting the nib lets the button go where it is")
require(p.touchEnded(x: 52, y: 62) == [], "... once")
require(p.touchMoved(x: 70, y: 70) == [], "a move with no touch is nothing")
require(p.hovered(x: 70, y: 70) == [.move(70, 70)], "hovering again moves it")
_ = p.touchBegan(x: 5, y: 5)
require(p.touchCancelled() == [.leftUp(5, 5)] && !p.down && p.touchCancelled() == [], "taken away: the button comes up, once")
_ = p.touchBegan(x: 8, y: 9)
require(p.reset() == [.leftUp(8, 9)] && !p.down, "switching the feature off lets the button go")
_ = p.touchBegan(x: 3, y: 3)
_ = p.touchEnded(x: 3, y: 3)
require(p.tapped(.right, at: (40, 41)) == [.click(.right, 40, 41)], "a squeeze clicks where the Pencil says")
require(p.tapped(.right, at: nil) == [.click(.right, 3, 3)], "... else where it last was")
require(p.tapped(.middle, at: (1, 2)) == [.click(.middle, 1, 2)] && p.tapped(.none, at: (1, 2)) == [], "a middle click, or nothing")
require(BCDPencilPointer().tapped(.right, at: nil) == [], "with nowhere known, nothing")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
