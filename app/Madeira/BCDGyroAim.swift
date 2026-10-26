// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Gyro aim (round 603): turning the phone aims the game. The phone's rotation moves the mouse or
// pushes the right stick of the game's controller, for a game with no touch aiming worth the name.
// Off for every game until its player turns it on (the game's line `gyro-aim`); while it is off
// nothing here exists: no sensor is started and no sample is looked at (BCDGyroLive.swift).
//
// This file is plain values and arithmetic, no engine or sensor type: the settings a game's lines
// make, how a rotation becomes "looking right and down" for the way the phone is held, and how
// that becomes mouse counts or a stick. BCDGyroLive.swift reads the sensor and posts the result.
//
// Directions. CoreMotion reports the rotation (rad/s, right-hand rule) about the phone's own axes:
// x along the screen's short side in portrait (to the right), y up the screen in portrait, z out of
// the screen. "Right" and "down" below are what the player sees: right = turning to the right,
// down = looking down, as mouse counts and a stick (up positive) have them.

struct BCDGyroVec: Equatable {
    var x = 0.0, y = 0.0, z = 0.0
    func dot(_ o: BCDGyroVec) -> Double { x * o.x + y * o.y + z * o.z }
    var length: Double { dot(self).squareRoot() }
}

/// How the phone is turned: UIInterfaceOrientation's four, by the side its bottom edge is on.
enum BCDGyroScreen: String, CaseIterable {
    case portrait, portraitUpsideDown
    /// The bottom edge (the home button's side) on the left: the phone turned clockwise from portrait.
    case landscapeLeft
    /// The bottom edge on the right: the phone turned counter-clockwise.
    case landscapeRight
}

struct BCDGyroSettings: Equatable {
    enum Target: String, CaseIterable { case off = "", mouse, stick }
    /// Which vertical the turning is measured around: the world's (gravity, so a phone tilted back still turns
    /// the view as an arm turns) or the screen's (the phone's own axis, as most gyro mappings do).
    enum Turn: String { case world = "", screen }

    var target: Target = .off
    /// A multiple: 1 is a turn of the phone through 90° a second for a full push of the stick, and 8 mouse counts a degree.
    var sensitivity = 1.0
    /// Degrees a second below which the phone is taken to be still.
    var deadzone = 0.5
    var invertX = false
    var invertY = false
    var turn: Turn = .world
    /// "" always on, else the controller input that must be held ("lt", "a", ...): BCDGyroHold.
    var hold = ""

    var isOn: Bool { target != .off }

    static let sensitivityChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
    static let deadzoneChoices: [Double] = [0, 0.25, 0.5, 1, 2, 4]
    static let sensitivityRange = 0.1...8.0, deadzoneRange = 0.0...10.0

    /// The game's lines. `gyro-aim`: mouse or stick (anything else: off). `gyro-sens`, `gyro-deadzone`: numbers, kept in
    /// range. `gyro-invert`: x, y or xy. `gyro-turn`: screen. `gyro-hold`: an input of BCDGyroHold, else always.
    static let keys = ["gyro-aim", "gyro-sens", "gyro-deadzone", "gyro-invert", "gyro-turn", "gyro-hold"]

    static func parse(_ get: (String) -> String?) -> BCDGyroSettings {
        var s = BCDGyroSettings()
        func word(_ key: String) -> String { (get(key) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        s.target = Target(rawValue: word("gyro-aim")) ?? .off
        if let v = Double(word("gyro-sens")), v.isFinite { s.sensitivity = min(max(v, sensitivityRange.lowerBound), sensitivityRange.upperBound) }
        if let v = Double(word("gyro-deadzone")), v.isFinite { s.deadzone = min(max(v, deadzoneRange.lowerBound), deadzoneRange.upperBound) }
        let invert = word("gyro-invert")
        s.invertX = invert.contains("x") || invert == "both"
        s.invertY = invert.contains("y") || invert == "both"
        s.turn = Turn(rawValue: word("gyro-turn")) ?? .world
        let hold = word("gyro-hold")
        s.hold = BCDGyroHold.inputs.contains(hold) ? hold : ""
        return s
    }

    /// The value of `gyro-invert` for the two flags ("" for neither).
    var invertWord: String { (invertX ? "x" : "") + (invertY ? "y" : "") }
}

/// "Only while a button is held": the controller input the gyro waits for. The state is the game's controller as the
/// game sees it, the on-screen one and a paired one merged.
enum BCDGyroHold {
    static let inputs = ["lt", "rt", "lb", "rb", "l3", "r3", "a", "b", "x", "y"]
    static let choices: [(String, String)] = [("", "Always")] + inputs.map { ($0, $0.uppercased()) }

    /// XInput's button bits (the same as TouchPadAction.buttons).
    static let masks: [String: UInt16] = ["lb": 0x0100, "rb": 0x0200, "l3": 0x0040, "r3": 0x0080,
                                          "a": 0x1000, "b": 0x2000, "x": 0x4000, "y": 0x8000]
    /// A trigger counts as held from a quarter of its travel.
    static let triggerThreshold: UInt8 = 64

    static func isOpen(_ hold: String, buttons: UInt16, lt: UInt8, rt: UInt8) -> Bool {
        switch hold {
        case "": return true
        case "lt": return lt >= triggerThreshold
        case "rt": return rt >= triggerThreshold
        default: return masks[hold].map { buttons & $0 != 0 } ?? true
        }
    }
}

enum BCDGyroMath {
    static let degreesPerRadian = 180.0 / Double.pi
    /// Mouse counts for a degree of turning at sensitivity 1.
    static let countsPerDegree = 8.0
    /// The turning rate (degrees a second) that pushes the stick all the way at sensitivity 1.
    static let stickFullRate = 90.0
    /// A stick pushed at all is pushed at least this far, past the dead zone most games keep (XInput's right stick
    /// 8689 of 32767), so a slow turn of the phone turns the view slowly instead of not at all.
    static let stickFloor = 0.27

    /// The screen's right and up, in the phone's own axes.
    static func screenAxes(_ screen: BCDGyroScreen) -> (right: BCDGyroVec, up: BCDGyroVec) {
        switch screen {
        case .portrait: return (BCDGyroVec(x: 1), BCDGyroVec(y: 1))
        case .portraitUpsideDown: return (BCDGyroVec(x: -1), BCDGyroVec(y: -1))
        case .landscapeLeft: return (BCDGyroVec(y: 1), BCDGyroVec(x: -1))
        case .landscapeRight: return (BCDGyroVec(y: -1), BCDGyroVec(x: 1))
        }
    }

    /// Turning to the right and looking down, in degrees a second, from the rotation rate (rad/s) and gravity.
    /// Turning is about the world's vertical (gravity) or the screen's; looking up and down is about the screen's
    /// horizontal either way. A rotation about an axis is positive counter-clockwise seen from the axis' tip:
    /// about up that is turning left, about the screen's right that is looking up.
    static func lookRates(rotation: BCDGyroVec, gravity: BCDGyroVec, screen: BCDGyroScreen, turn: BCDGyroSettings.Turn)
        -> (right: Double, down: Double) {
        let axes = screenAxes(screen)
        let verticalRate: Double
        if turn == .world, gravity.length > 0.5 {
            // up = -gravity: a rotation about up is a turn to the left.
            verticalRate = rotation.dot(BCDGyroVec(x: -gravity.x / gravity.length, y: -gravity.y / gravity.length, z: -gravity.z / gravity.length))
        } else {
            verticalRate = rotation.dot(axes.up)
        }
        return (-verticalRate * degreesPerRadian, -rotation.dot(axes.right) * degreesPerRadian)
    }

    /// The rates as the settings shape them: inverted if asked, and a radial dead zone that starts the output from nothing
    /// at its edge instead of jumping.
    static func shaped(_ rates: (right: Double, down: Double), _ s: BCDGyroSettings) -> (right: Double, down: Double) {
        guard rates.right.isFinite, rates.down.isFinite else { return (0, 0) }
        var r = rates.right * (s.invertX ? -1 : 1), d = rates.down * (s.invertY ? -1 : 1)
        let m = (r * r + d * d).squareRoot()
        guard m > s.deadzone, m > 0 else { return (0, 0) }
        let k = (m - s.deadzone) / m
        r *= k; d *= k
        return (r, d)
    }

    /// Whole mouse counts, keeping the fractions for the next sample.
    struct Carry: Equatable {
        private(set) var x = 0.0, y = 0.0
        mutating func add(_ dx: Double, _ dy: Double) -> (dx: Int32, dy: Int32) {
            guard dx.isFinite, dy.isFinite else { return (0, 0) }
            x += dx; y += dy
            let ix = Int32(max(-30000, min(30000, x))), iy = Int32(max(-30000, min(30000, y)))
            x -= Double(ix); y -= Double(iy)
            return (ix, iy)
        }
        mutating func reset() { x = 0; y = 0 }
    }

    /// Mouse counts for `dt` seconds of the shaped rates. `dt` is bounded: a stalled sensor must not fling the view.
    static func mouse(_ rates: (right: Double, down: Double), dt: Double, _ s: BCDGyroSettings, carry: inout Carry) -> (dx: Int32, dy: Int32) {
        let t = max(0, min(dt, 0.1))
        let k = t * countsPerDegree * s.sensitivity
        return carry.add(rates.right * k, rates.down * k)
    }

    /// The right stick (x right, y up, XInput's full range) for the shaped rates: linear to a full push at the full rate,
    /// and never less than the floor once pushed.
    static func stick(_ rates: (right: Double, down: Double), _ s: BCDGyroSettings) -> (rx: Int16, ry: Int16) {
        let full = stickFullRate / s.sensitivity
        let x = rates.right / full, y = -rates.down / full
        let m = (x * x + y * y).squareRoot()
        guard m > 0, m.isFinite else { return (0, 0) }
        let out = stickFloor + (1 - stickFloor) * min(m, 1)
        return (axis(x / m * out), axis(y / m * out))
    }

    /// XInput's axis range (-32768...32767).
    static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let v = max(-1, min(1, value))
        return Int16((v * (v < 0 ? 32768 : 32767)).rounded())
    }

    /// The controller's right stick with the gyro's: a stick the player pushes past XInput's dead zone wins, else the gyro's
    /// when it pushes at all (the touch stick's rule, GamepadSample.merge).
    static func merged(physical: (rx: Int16, ry: Int16), gyro: (rx: Int16, ry: Int16)) -> (rx: Int16, ry: Int16) {
        let p = (Double(physical.rx) * Double(physical.rx) + Double(physical.ry) * Double(physical.ry)).squareRoot()
        if p > 8689 || (gyro.rx == 0 && gyro.ry == 0) { return physical }
        return gyro
    }
}
