// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-gestures.py. That script compiles this file as main.swift together with
// app/Madeira/BCDKeyNames.swift, BCDExtraKeys.swift, BCDTurbo.swift, BCDInputActions.swift and BCDGestureMap.swift and runs it: the
// bindings a game's lines make, and which gesture a set of fingers made (taps with two to four, swipes with two or three, a pinch in
// or out) and which touches are no gesture at all.
import CoreGraphics
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

// ---- the bindings -----------------------------------------------------------------------------------------------------
func map(_ lines: [String: String]) -> BCDGestureSettings { BCDGestureSettings.parse { lines[$0] } }
require(map([:]) == BCDGestureSettings() && !map([:]).isOn, "no lines: nothing bound")
let bound = map(["gesture-tap2": "esc", "gesture-swipe3-up": "menu", "gesture-pinch-out": "wheel-up", "gesture-tap4": "alt+tab"])
require(bound.isOn && bound.bindings[.tap2] == .key(0x1B) && bound.bindings[.swipe3Up] == .menu && bound.bindings[.pinchOut] == .wheel(1) && bound.bindings[.tap4] == .chord([0x12], 0x09), "a gesture and its action")
require(map(["gesture-tap2": "nonsense"]).bindings.isEmpty && map(["gesture-tap2": ""]).bindings.isEmpty && map(["gesture-tap2": "none"]).bindings.isEmpty, "a name this build does not know binds nothing")
require(map(["gesture-tap9": "esc"]).bindings.isEmpty, "a gesture this build does not know is none")
require(BCDGesture.allCases.count == 13 && BCDGestureSettings.lineNames.count == 13 && Set(BCDGestureSettings.lineNames).count == 13, "thirteen gestures, thirteen lines")
require(BCDGesture.allCases.allSatisfy { !$0.title.isEmpty && $0.line == "gesture-" + $0.rawValue }, "each with words and its line")

// ---- recognising -------------------------------------------------------------------------------------------------------
/// Fingers land together, optionally move, and lift together.
func gesture(_ fingers: [(CGPoint, CGPoint)], landAt: Double = 0, spread: Double = 0.02, liftAt: Double = 0.2) -> BCDGesture? {
    var tracker = BCDGestureTracker()
    for (i, f) in fingers.enumerated() { tracker.down(id: i, at: f.0, time: landAt + Double(i) * spread) }
    for (i, f) in fingers.enumerated() { tracker.move(id: i, to: f.1) }
    var result: BCDGesture?
    for (i, f) in fingers.enumerated() { if let g = tracker.up(id: i, at: f.1, time: liftAt + Double(i) * 0.01) { result = g } }
    return result
}
func still(_ n: Int) -> [(CGPoint, CGPoint)] {
    var out: [(CGPoint, CGPoint)] = []
    for i in 0..<n {
        let x = CGFloat(300 + i * 60)
        out.append((CGPoint(x: x, y: 200), CGPoint(x: x + 2, y: 201)))
    }
    return out
}
func moving(_ n: Int, dx: Double, dy: Double) -> [(CGPoint, CGPoint)] {
    var out: [(CGPoint, CGPoint)] = []
    for i in 0..<n {
        let x = CGFloat(300 + i * 60)
        out.append((CGPoint(x: x, y: 200), CGPoint(x: x + CGFloat(dx), y: 200 + CGFloat(dy))))
    }
    return out
}
require(gesture(still(2)) == .tap2 && gesture(still(3)) == .tap3 && gesture(still(4)) == .tap4, "a tap with two, three and four fingers")
require(gesture(still(1)) == nil, "one finger is no gesture")
require(gesture(still(5)) == nil, "five fingers are none")
require(gesture(still(2), liftAt: 0.5) == nil && gesture(still(2), liftAt: 0.44) == .tap2, "a tap is quick: 0.45 seconds")
require(gesture(still(3), landAt: 0, spread: 0.12, liftAt: 0.4) == .tap3, "fingers that land within 0.3 seconds of the first are together")
require(gesture(still(3), landAt: 0, spread: 0.4, liftAt: 0.9) == nil, "a finger that lands long after the first is not part of it")
require(gesture(moving(2, dx: 20, dy: 0), liftAt: 0.2) == nil, "fingers that moved 20 points are no tap and no swipe")
require(gesture(moving(2, dx: -120, dy: 0)) == .swipe2Left && gesture(moving(2, dx: 120, dy: 0)) == .swipe2Right, "swipes with two fingers, left and right")
require(gesture(moving(2, dx: 0, dy: -120)) == .swipe2Up && gesture(moving(2, dx: 0, dy: 120)) == .swipe2Down, "... up and down")
require(gesture(moving(3, dx: -120, dy: 0)) == .swipe3Left && gesture(moving(3, dx: 120, dy: 0)) == .swipe3Right, "swipes with three fingers")
require(gesture(moving(3, dx: 0, dy: -120)) == .swipe3Up && gesture(moving(3, dx: 0, dy: 120)) == .swipe3Down, "... up and down")
require(gesture(moving(4, dx: 120, dy: 0)) == nil, "four fingers have no swipe")
require(gesture(moving(2, dx: 50, dy: 0)) == nil, "a swipe has to be 70 points")
require(gesture(moving(2, dx: 90, dy: 80)) == nil, "a slanted swipe is none (one direction must win by half again)")
require(gesture(moving(2, dx: 100, dy: 40)) == .swipe2Right, "... a mostly sideways one is sideways")
require(gesture(moving(2, dx: 120, dy: 0), liftAt: 1.2) == nil, "a swipe is not slow: one second")
func pinch(from: Double, to: Double) -> BCDGesture? {
    gesture([(CGPoint(x: 400 - from / 2, y: 200), CGPoint(x: 400 - to / 2, y: 200)), (CGPoint(x: 400 + from / 2, y: 200), CGPoint(x: 400 + to / 2, y: 200))])
}
require(pinch(from: 100, to: 200) == .pinchOut && pinch(from: 200, to: 100) == .pinchIn, "two fingers moving apart and together")
require(pinch(from: 100, to: 110) == .tap2 || pinch(from: 100, to: 110) == nil, "a small change in spread is not a pinch")
require(pinch(from: 100, to: 120) != .pinchOut && pinch(from: 100, to: 120) != .pinchIn, "... 1.2 times is not enough")
require(pinch(from: 100, to: 135) == .pinchOut && pinch(from: 135, to: 100) == .pinchIn, "... 1.35 times is")
// A swipe with a changing spread.
let drifting = gesture([(CGPoint(x: 300, y: 200), CGPoint(x: 160, y: 200)), (CGPoint(x: 360, y: 200), CGPoint(x: 360, y: 200))])
require(drifting == nil, "fingers that swipe and spread at once make none")
// Lifting one by one.
var tracker = BCDGestureTracker()
tracker.down(id: 1, at: CGPoint(x: 100, y: 100), time: 0)
tracker.down(id: 2, at: CGPoint(x: 160, y: 100), time: 0.05)
require(tracker.up(id: 1, at: CGPoint(x: 101, y: 100), time: 0.15) == nil && tracker.isTracking, "the first finger up: not yet")
require(tracker.up(id: 2, at: CGPoint(x: 161, y: 100), time: 0.2) == .tap2 && !tracker.isTracking, "the last up: the tap")
require(tracker.up(id: 9, at: .zero, time: 1) == nil, "a finger that was never down is nothing")
// A gesture does not leak into the next one.
tracker.down(id: 1, at: CGPoint(x: 100, y: 100), time: 2)
require(tracker.up(id: 1, at: CGPoint(x: 100, y: 100), time: 2.1) == nil, "a single tap after a gesture is none")
tracker.down(id: 1, at: CGPoint(x: 100, y: 100), time: 3)
tracker.down(id: 2, at: CGPoint(x: 160, y: 100), time: 3.02)
tracker.cancel()
require(!tracker.isTracking, "taken away: nothing left")
tracker.down(id: 1, at: CGPoint(x: 100, y: 100), time: 4)
tracker.down(id: 2, at: CGPoint(x: 160, y: 100), time: 4.02)
_ = tracker.up(id: 1, at: CGPoint(x: 100, y: 100), time: 4.1)
require(tracker.up(id: 2, at: CGPoint(x: 160, y: 100), time: 4.12) == .tap2, "and a new gesture is read from its own fingers")
// One finger down, up, and another two shortly after.
var mixed = BCDGestureTracker()
mixed.down(id: 1, at: CGPoint(x: 100, y: 100), time: 0)
_ = mixed.up(id: 1, at: CGPoint(x: 100, y: 100), time: 0.05)
mixed.down(id: 2, at: CGPoint(x: 200, y: 100), time: 0.1)
mixed.down(id: 3, at: CGPoint(x: 260, y: 100), time: 0.12)
_ = mixed.up(id: 2, at: CGPoint(x: 200, y: 100), time: 0.2)
require(mixed.up(id: 3, at: CGPoint(x: 260, y: 100), time: 0.22) == .tap2, "two fingers after a lone tap are a tap of two (each gesture is its own set of fingers)")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
