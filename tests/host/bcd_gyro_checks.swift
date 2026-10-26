// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-gyro.py. That script compiles this file as main.swift together with
// app/Madeira/BCDGyroAim.swift (plain Foundation) and runs it: the settings a game's lines make, which way a turn of
// the phone aims in each way of holding it, the mouse counts and the stick it makes, and the hold gate.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

// ---- the settings ----------------------------------------------------------------------------------
func settings(_ lines: [String: String]) -> BCDGyroSettings { BCDGyroSettings.parse { lines[$0] } }
require(settings([:]) == BCDGyroSettings() && !settings([:]).isOn, "no lines: off, with the default values")
require(settings(["gyro-aim": "mouse"]).target == .mouse && settings(["gyro-aim": " Stick "]).target == .stick, "gyro-aim: mouse or stick, any case")
require(settings(["gyro-aim": "on"]).target == .off && settings(["gyro-aim": "1"]).target == .off && settings(["gyro-aim": ""]).target == .off,
        "anything else is off")
require(near(settings(["gyro-sens": "2.5"]).sensitivity, 2.5) && near(settings(["gyro-sens": "100"]).sensitivity, 8) && near(settings(["gyro-sens": "0"]).sensitivity, 0.1)
        && near(settings(["gyro-sens": "x"]).sensitivity, 1) && near(settings(["gyro-sens": "nan"]).sensitivity, 1), "gyro-sens is kept in range, a bad one is the default")
require(near(settings(["gyro-deadzone": "2"]).deadzone, 2) && near(settings(["gyro-deadzone": "-4"]).deadzone, 0) && near(settings(["gyro-deadzone": "99"]).deadzone, 10)
        && near(settings(["gyro-deadzone": "inf"]).deadzone, 0.5), "gyro-deadzone likewise")
require(settings(["gyro-invert": "x"]).invertX && !settings(["gyro-invert": "x"]).invertY, "invert x")
require(!settings(["gyro-invert": "y"]).invertX && settings(["gyro-invert": "y"]).invertY, "invert y")
require(settings(["gyro-invert": "xy"]).invertX && settings(["gyro-invert": "xy"]).invertY && settings(["gyro-invert": "both"]).invertY, "invert both")
require(!settings([:]).invertX && !settings([:]).invertY && !settings(["gyro-invert": "no"]).invertX && !settings(["gyro-invert": "no"]).invertY,
        "no invert by default")
require(settings(["gyro-turn": "screen"]).turn == .screen && settings(["gyro-turn": "world"]).turn == .world && settings([:]).turn == .world, "gyro-turn")
require(settings(["gyro-hold": "LT"]).hold == "lt" && settings(["gyro-hold": "a"]).hold == "a" && settings(["gyro-hold": "start"]).hold == "" && settings([:]).hold == "",
        "gyro-hold: a known input, else always")
var both = BCDGyroSettings(); both.invertX = true; both.invertY = true
require(both.invertWord == "xy" && BCDGyroSettings().invertWord == "", "invertWord writes what parse reads")
let words = settings(["gyro-invert": both.invertWord])
require(words.invertX && words.invertY, "... and back")
require(BCDGyroSettings.keys.count == 6 && Set(BCDGyroSettings.keys).count == 6, "six lines")
require(BCDGyroSettings.sensitivityChoices.allSatisfy { BCDGyroSettings.sensitivityRange.contains($0) }
        && BCDGyroSettings.deadzoneChoices.allSatisfy { BCDGyroSettings.deadzoneRange.contains($0) }, "every offered value is in range")

// ---- the hold gate ---------------------------------------------------------------------------------
require(BCDGyroHold.isOpen("", buttons: 0, lt: 0, rt: 0), "always: open")
require(!BCDGyroHold.isOpen("lt", buttons: 0xFFFF, lt: 63, rt: 255) && BCDGyroHold.isOpen("lt", buttons: 0, lt: 64, rt: 0), "LT: a quarter of its travel")
require(BCDGyroHold.isOpen("rt", buttons: 0, lt: 0, rt: 200) && !BCDGyroHold.isOpen("rt", buttons: 0xFFFF, lt: 255, rt: 0), "RT")
let masks: [String: UInt16] = ["lb": 0x0100, "rb": 0x0200, "l3": 0x0040, "r3": 0x0080, "a": 0x1000, "b": 0x2000, "x": 0x4000, "y": 0x8000]
for (name, mask) in masks.sorted(by: { $0.key < $1.key }) {
    require(BCDGyroHold.isOpen(name, buttons: mask, lt: 0, rt: 0) && !BCDGyroHold.isOpen(name, buttons: ~mask, lt: 255, rt: 255), "\(name): its button only")
}
require(BCDGyroHold.inputs.count == 10 && BCDGyroHold.choices.count == 11 && BCDGyroHold.choices[0].0 == "", "ten inputs, and always")
require(BCDGyroHold.isOpen("nonsense", buttons: 0, lt: 0, rt: 0), "an unknown input never shuts the gyro")

// ---- which way a turn aims -------------------------------------------------------------------------
let rate = 1.0   // rad/s
// The phone upright in each way of holding it (gravity in its own axes); the player turns right, looks down.
struct Hold { var screen: BCDGyroScreen; var gravity: BCDGyroVec }
let holds = [
    Hold(screen: .portrait, gravity: BCDGyroVec(x: 0, y: -1, z: 0)),
    Hold(screen: .portraitUpsideDown, gravity: BCDGyroVec(x: 0, y: 1, z: 0)),
    Hold(screen: .landscapeLeft, gravity: BCDGyroVec(x: 1, y: 0, z: 0)),     // screen-up is -x, so down is +x
    Hold(screen: .landscapeRight, gravity: BCDGyroVec(x: -1, y: 0, z: 0)),   // screen-up is +x, so down is -x
]
for h in holds {
    let axes = BCDGyroMath.screenAxes(h.screen)
    // The screen's up is against gravity when the phone is upright.
    require(near(axes.up.dot(h.gravity), -1), "\(h.screen): the screen's up is against gravity when upright")
    // The axes make a right-handed frame with the screen normal z.
    let cross = BCDGyroVec(x: axes.right.y * axes.up.z - axes.right.z * axes.up.y, y: axes.right.z * axes.up.x - axes.right.x * axes.up.z,
                           z: axes.right.x * axes.up.y - axes.right.y * axes.up.x)
    require(near(cross.x, 0) && near(cross.y, 0) && near(cross.z, 1), "\(h.screen): right x up is out of the screen")
    for turn in [BCDGyroSettings.Turn.world, .screen] {
        // Turning right is clockwise seen from above: negative about up.
        let turnRight = BCDGyroVec(x: -rate * axes.up.x, y: -rate * axes.up.y, z: -rate * axes.up.z)
        let r = BCDGyroMath.lookRates(rotation: turnRight, gravity: h.gravity, screen: h.screen, turn: turn)
        require(near(r.right, rate * BCDGyroMath.degreesPerRadian) && near(r.down, 0), "\(h.screen) \(turn): turning right looks right, \(r)")
        // Looking down is negative about the screen's right.
        let lookDown = BCDGyroVec(x: -rate * axes.right.x, y: -rate * axes.right.y, z: -rate * axes.right.z)
        let d = BCDGyroMath.lookRates(rotation: lookDown, gravity: h.gravity, screen: h.screen, turn: turn)
        require(near(d.down, rate * BCDGyroMath.degreesPerRadian) && near(d.right, 0), "\(h.screen) \(turn): tilting forward looks down, \(d)")
    }
}
// Portrait is the plain case: x right, y up: a rotation about y turns, about x looks.
let plain = BCDGyroMath.lookRates(rotation: BCDGyroVec(x: 0, y: -1, z: 0), gravity: BCDGyroVec(x: 0, y: -1, z: 0), screen: .portrait, turn: .world)
require(plain.right > 0 && near(plain.down, 0), "portrait, negative about y: right")
let plain2 = BCDGyroMath.lookRates(rotation: BCDGyroVec(x: -1, y: 0, z: 0), gravity: BCDGyroVec(x: 0, y: -1, z: 0), screen: .portrait, turn: .world)
require(plain2.down > 0 && near(plain2.right, 0), "portrait, negative about x: down")

// The phone in landscape (home button on the right), tilted back until its screen faces up at 45 degrees: gravity is half
// along the phone's x (against the screen's up) and half into the screen. A turn of the arms is a rotation about the world's
// vertical, which is half along the screen's up and half out of the screen.
let c = 0.7071067811865476
let tilted = BCDGyroVec(x: -c, y: 0, z: -c)
let worldUp = BCDGyroVec(x: c, y: 0, z: c)
let arms = BCDGyroVec(x: -rate * worldUp.x, y: 0, z: -rate * worldUp.z)   // clockwise seen from above: turning right
let w = BCDGyroMath.lookRates(rotation: arms, gravity: tilted, screen: .landscapeRight, turn: .world)
require(near(w.right, rate * BCDGyroMath.degreesPerRadian) && near(w.down, 0), "tilted back, a turn of the arms is a full turn right in world mode: \(w)")
let sc = BCDGyroMath.lookRates(rotation: arms, gravity: tilted, screen: .landscapeRight, turn: .screen)
require(near(sc.right, rate * BCDGyroMath.degreesPerRadian * c) && near(sc.down, 0), "... and only the screen's share of it (cos 45) in screen mode: \(sc)")
let spin = BCDGyroVec(x: 0, y: 0, z: -rate)       // about the screen's normal only
let lonely = BCDGyroMath.lookRates(rotation: spin, gravity: tilted, screen: .landscapeRight, turn: .screen)
require(near(lonely.right, 0) && near(lonely.down, 0), "a spin about the screen normal aims nothing in screen mode")
require(near(BCDGyroMath.lookRates(rotation: spin, gravity: tilted, screen: .landscapeRight, turn: .world).right, rate * BCDGyroMath.degreesPerRadian * c),
        "... but turns the view in world mode, which follows gravity")
let noGravity = BCDGyroMath.lookRates(rotation: BCDGyroVec(x: 0, y: -1, z: 0), gravity: BCDGyroVec(), screen: .portrait, turn: .world)
require(noGravity.right > 0, "without a gravity reading the world's turn falls back to the screen's")

// ---- shaping ---------------------------------------------------------------------------------------
var s = BCDGyroSettings(); s.deadzone = 1
require(BCDGyroMath.shaped((0.5, 0.5), s) == (0, 0), "inside the dead zone: nothing")
let edge = BCDGyroMath.shaped((1.0001, 0), s)
require(edge.right > 0 && edge.right < 0.001, "just outside it: almost nothing (no jump)")
let big = BCDGyroMath.shaped((11, 0), s)
require(near(big.right, 10), "far outside: the rate less the dead zone")
let radial = BCDGyroMath.shaped((3, 4), s)
require(near(radial.right, 2.4) && near(radial.down, 3.2), "the dead zone is radial: (3, 4) less 1 is (2.4, 3.2), the direction stays")
s.invertX = true
require(BCDGyroMath.shaped((11, 0), s).right < 0, "invert x")
s.invertX = false; s.invertY = true
require(BCDGyroMath.shaped((0, 11), s).down < 0, "invert y")
require(BCDGyroMath.shaped((.nan, 1), s) == (0, 0) && BCDGyroMath.shaped((.infinity, 1), s) == (0, 0), "a bad sample gives nothing")
s.deadzone = 0
require(BCDGyroMath.shaped((0, 0), s) == (0, 0), "no dead zone, no motion: nothing")

// ---- mouse -----------------------------------------------------------------------------------------
var carry = BCDGyroMath.Carry()
var m = BCDGyroSettings()
let one = BCDGyroMath.mouse((10, 0), dt: 0.01, m, carry: &carry)   // 10 deg/s for 10 ms = 0.1 deg = 0.8 count
require(one.dx == 0 && one.dy == 0, "a tenth of a degree is less than a count")
var total: Int32 = one.dx
for _ in 0..<99 { total += BCDGyroMath.mouse((10, 0), dt: 0.01, m, carry: &carry).dx }
require(total == 80, "a second of 10 degrees a second is 10 degrees, 80 counts at sensitivity 1, none lost to rounding: \(total)")
m.sensitivity = 2
carry.reset()
total = 0
for _ in 0..<100 { total += BCDGyroMath.mouse((10, 0), dt: 0.01, m, carry: &carry).dx }
require(total == 160, "sensitivity 2 doubles it: \(total)")
carry.reset()
let down = BCDGyroMath.mouse((0, 100), dt: 0.01, m, carry: &carry)
require(down.dx == 0 && down.dy == 16, "looking down is positive y (the mouse's): \(down)")
let left = BCDGyroMath.mouse((-100, 0), dt: 0.01, m, carry: &carry)
require(left.dx == -16, "turning left is negative x: \(left)")
carry.reset()
require(BCDGyroMath.mouse((100, 0), dt: 5, m, carry: &carry).dx == Int32(0.1 * 8 * 2 * 100), "a stalled sensor's long gap counts as 100 ms")
require(BCDGyroMath.mouse((100, 0), dt: -1, m, carry: &carry) == (0, 0), "a backwards clock counts nothing")
carry.reset()
require(BCDGyroMath.mouse((.nan, 0), dt: 0.01, m, carry: &carry) == (0, 0) && carry == BCDGyroMath.Carry(), "a bad sample leaves the carry alone")

// ---- stick -----------------------------------------------------------------------------------------
var st = BCDGyroSettings()
require(BCDGyroMath.stick((0, 0), st) == (0, 0), "still: the stick rests")
let slow = BCDGyroMath.stick((1, 0), st)
require(slow.rx > 8689 && slow.ry == 0, "a slow turn is past the game's dead zone (XInput's 8689): \(slow)")
require(near(Double(slow.rx) / 32767, 0.27 + 0.73 / 90, 0.002), "... at the floor plus the little the turn adds: \(slow.rx)")
require(BCDGyroMath.stick((90, 0), st) == (32767, 0), "90 degrees a second pushes it all the way right")
require(BCDGyroMath.stick((-90, 0), st) == (-32768, 0), "... and left")
require(BCDGyroMath.stick((900, 0), st) == (32767, 0), "more is the same")
let up = BCDGyroMath.stick((0, -90), st)
require(up.rx == 0 && up.ry == 32767, "looking up is the stick up (positive y)")
require(BCDGyroMath.stick((0, 90), st) == (0, -32768), "looking down is the stick down")
let diag = BCDGyroMath.stick((90, 90), st)
require(diag.rx > 0 && diag.ry < 0 && abs(Int(diag.rx) + Int(diag.ry)) <= 1, "diagonal: both axes, equal and opposite, no more than a full push in all (\(diag))")
let radius = (Double(diag.rx) * Double(diag.rx) + Double(diag.ry) * Double(diag.ry)).squareRoot()
require(radius <= 32768 * 1.0001, "... the length of a full push at most: \(radius)")
st.sensitivity = 2
require(BCDGyroMath.stick((45, 0), st) == (32767, 0), "sensitivity 2 pushes all the way at 45 degrees a second")
require(BCDGyroMath.stick((.nan, 1), st) == (0, 0), "a bad sample rests the stick")
require(BCDGyroMath.axis(2) == 32767 && BCDGyroMath.axis(-2) == -32768 && BCDGyroMath.axis(0) == 0 && BCDGyroMath.axis(.nan) == 0, "XInput's range")

// ---- with the controller's own stick ---------------------------------------------------------------
require(BCDGyroMath.merged(physical: (0, 0), gyro: (100, -200)) == (100, -200), "a resting stick lets the gyro through")
require(BCDGyroMath.merged(physical: (5000, 3000), gyro: (100, -200)) == (100, -200), "a stick inside the dead zone does too")
require(BCDGyroMath.merged(physical: (20000, 0), gyro: (100, -200)) == (20000, 0), "a stick pushed past it wins")
require(BCDGyroMath.merged(physical: (5000, 3000), gyro: (0, 0)) == (5000, 3000), "no gyro: the stick as it is")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures != 0 { exit(1) }
