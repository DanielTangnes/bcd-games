// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Turbo and macros (round 604). Per game, off until its player turns them on from the game's page
// (Turbo and macros) or the in-game menu (Controls):
//
// - Turbo: hold a button of the controller (the on-screen one or a paired one) and the game sees it
//   pressed and let go again and again, ten times a second or as chosen. The same for the mouse buttons
//   and a few keys of the touch controls.
// - Macros: a button of the controller plays a short chain of presses instead of itself: once ("A, A, B"),
//   again and again while it is held, or held down until it is pressed again (a sprint that stays on).
//
// This file is plain values and rules, Foundation only: what a game's lines make, and the clocks that
// decide, at a moment in milliseconds, which inputs are down. BCDTurboLive.swift reads the game's lines
// and puts the result into the controller's state (GamepadInput) and the touch controls' key events.
// Nothing here has a timer or reads a clock: the caller passes `now`.

// MARK: - The controller's inputs

/// An input of player 1's controller, by the name the settings store (and XInput's bit for it).
enum BCDPadInput: String, CaseIterable {
    case a, b, x, y, lb, rb, lt, rt, l3, r3, up, down, left, right, start, back

    /// XInput's button bit; 0 for the triggers, which are analogue.
    var mask: UInt16 {
        switch self {
        case .a: return 0x1000
        case .b: return 0x2000
        case .x: return 0x4000
        case .y: return 0x8000
        case .lb: return 0x0100
        case .rb: return 0x0200
        case .l3: return 0x0040
        case .r3: return 0x0080
        case .up: return 0x0001
        case .down: return 0x0002
        case .left: return 0x0004
        case .right: return 0x0008
        case .start: return 0x0010
        case .back: return 0x0020
        case .lt, .rt: return 0
        }
    }

    var isTrigger: Bool { self == .lt || self == .rt }

    var title: String {
        switch self {
        case .a, .b, .x, .y: return rawValue.uppercased()
        case .lb, .rb, .lt, .rt, .l3, .r3: return rawValue.uppercased()
        case .up: return "D-pad up"
        case .down: return "D-pad down"
        case .left: return "D-pad left"
        case .right: return "D-pad right"
        case .start: return "Menu"
        case .back: return "View"
        }
    }

    /// The inputs turbo and a macro's button can name: the face buttons, bumpers, triggers and stick clicks.
    static let main: [BCDPadInput] = [.a, .b, .x, .y, .lb, .rb, .lt, .rt, .l3, .r3]

    static func named(_ text: String) -> BCDPadInput? { BCDPadInput(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) }
}

/// The part of player 1's controller state that turbo and macros read and write.
struct BCDPadBits: Equatable {
    var buttons: UInt16 = 0
    var lt: UInt8 = 0
    var rt: UInt8 = 0

    /// A trigger counts as held from a quarter of its travel (the gyro's hold gate uses the same).
    static let triggerThreshold: UInt8 = 64

    func holds(_ input: BCDPadInput) -> Bool {
        switch input {
        case .lt: return lt >= Self.triggerThreshold
        case .rt: return rt >= Self.triggerThreshold
        default: return buttons & input.mask != 0
        }
    }

    mutating func press(_ input: BCDPadInput) {
        switch input {
        case .lt: lt = 255
        case .rt: rt = 255
        default: buttons |= input.mask
        }
    }

    mutating func clear(_ input: BCDPadInput) {
        switch input {
        case .lt: lt = 0
        case .rt: rt = 0
        default: buttons &= ~input.mask
        }
    }

    mutating func add(_ other: BCDPadBits) {
        buttons |= other.buttons
        lt = max(lt, other.lt)
        rt = max(rt, other.rt)
    }

    var isEmpty: Bool { buttons == 0 && lt == 0 && rt == 0 }
}

// MARK: - Turbo

struct BCDTurboSettings: Equatable {
    /// Controller inputs that repeat while held, in the order of `BCDPadInput.main`.
    var pad: [BCDPadInput] = []
    var mouseLeft = false
    var mouseRight = false
    /// Windows virtual-key codes of touch-control keys that repeat while held.
    var keys: [Int32] = []
    /// Presses a second.
    var rate = BCDTurboSettings.defaultRate

    static let defaultRate = 10
    static let rateChoices = [5, 8, 10, 12, 15, 20, 30]
    static let rateRange = 2...30
    /// The lines of a game this feature keeps: `turbo` (a list of names), `turbo-keys` (a list of key names), `turbo-rate`.
    static let lineNames = ["turbo", "turbo-keys", "turbo-rate"]
    static let mouseLeftName = "mouse-left", mouseRightName = "mouse-right"

    var padOn: Bool { !pad.isEmpty }
    var touchOn: Bool { mouseLeft || mouseRight || !keys.isEmpty }
    var isOn: Bool { padOn || touchOn }

    static func parse(_ get: (String) -> String?) -> BCDTurboSettings {
        var s = BCDTurboSettings()
        let names = (get("turbo") ?? "").lowercased().split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        for name in names {
            if let input = BCDPadInput.named(name), BCDPadInput.main.contains(input) {
                if !s.pad.contains(input) { s.pad.append(input) }
            } else if name == mouseLeftName {
                s.mouseLeft = true
            } else if name == mouseRightName {
                s.mouseRight = true
            }
        }
        s.pad.sort { BCDPadInput.main.firstIndex(of: $0)! < BCDPadInput.main.firstIndex(of: $1)! }
        s.keys = BCDKeyNames.parseList(get("turbo-keys") ?? "")
        if let text = get("turbo-rate")?.trimmingCharacters(in: .whitespaces), let v = Int(text) {
            s.rate = min(max(v, rateRange.lowerBound), rateRange.upperBound)
        }
        return s
    }

    /// The value of the `turbo` line.
    var line: String {
        pad.map(\.rawValue).joined(separator: ",") + (mouseLeft ? (pad.isEmpty ? "" : ",") + Self.mouseLeftName : "")
            + (mouseRight ? (pad.isEmpty && !mouseLeft ? "" : ",") + Self.mouseRightName : "")
    }

    /// The `turbo` line with one name switched on or off.
    static func toggled(_ line: String, name: String, on: Bool) -> String {
        var s = parse { $0 == "turbo" ? line : nil }
        if let input = BCDPadInput.named(name) {
            if on && !s.pad.contains(input) && BCDPadInput.main.contains(input) { s.pad.append(input) }
            if !on { s.pad.removeAll { $0 == input } }
            s.pad.sort { BCDPadInput.main.firstIndex(of: $0)! < BCDPadInput.main.firstIndex(of: $1)! }
        } else if name == mouseLeftName {
            s.mouseLeft = on
        } else if name == mouseRightName {
            s.mouseRight = on
        }
        return s.line
    }

    func holds(name: String) -> Bool {
        if name == Self.mouseLeftName { return mouseLeft }
        if name == Self.mouseRightName { return mouseRight }
        return BCDPadInput.named(name).map(pad.contains) ?? false
    }
}

/// When a held, turbo input is down: pressed first, then let go for the second half of each period.
enum BCDTurboClock {
    /// Milliseconds from one press to the next.
    static func period(rate: Int) -> Int { max(2, 1000 / max(1, rate)) }

    /// Whether the input is down `elapsed` milliseconds after it was first held.
    static func isDown(elapsed: Int, rate: Int) -> Bool {
        let p = period(rate: rate)
        return max(0, elapsed) % p < max(1, p / 2)
    }
}

/// Turbo on the controller: remembers when each turbo input was first held and lets it through only
/// in the down half of its period.
struct BCDTurboGate {
    private var since: [BCDPadInput: UInt64] = [:]

    /// Gates `bits` in place; true while a turbo input is held (the caller keeps sampling).
    mutating func apply(_ settings: BCDTurboSettings, _ bits: inout BCDPadBits, now: UInt64) -> Bool {
        var any = false
        for input in settings.pad {
            if bits.holds(input) {
                let t0 = since[input] ?? now
                since[input] = t0
                any = true
                if !BCDTurboClock.isDown(elapsed: Int(clamping: now &- t0), rate: settings.rate) { bits.clear(input) }
            } else {
                since[input] = nil
            }
        }
        if since.count > 0 { since = since.filter { settings.pad.contains($0.key) } }
        return any
    }

    mutating func reset() { since.removeAll() }
}

// MARK: - Macros

struct BCDMacro: Equatable {
    enum Mode: String, CaseIterable {
        /// The steps play once for each press of the button.
        case once = ""
        /// The steps play again and again while the button is held.
        case repeating = "repeat"
        /// A press holds every input of the steps down; the next press lets them go.
        case hold
    }

    var trigger: BCDPadInput
    var mode: Mode
    /// Each step is a chord of inputs pressed together; an empty step is a pause.
    var steps: [[BCDPadInput]]
    /// Milliseconds a step is held, and the same again before the next one.
    var stepMillis: Int

    var total: Int { steps.count * 2 * stepMillis }

    /// What the steps press at `elapsed` milliseconds into a run.
    func output(at elapsed: Int) -> BCDPadBits {
        var bits = BCDPadBits()
        guard !steps.isEmpty, elapsed >= 0 else { return bits }
        let slot = elapsed / (2 * stepMillis)
        guard slot < steps.count, elapsed % (2 * stepMillis) < stepMillis else { return bits }
        steps[slot].forEach { bits.press($0) }
        return bits
    }

    /// Every input of the steps together (what `hold` keeps down).
    var held: BCDPadBits {
        var bits = BCDPadBits()
        steps.joined().forEach { bits.press($0) }
        return bits
    }
}

struct BCDMacroSettings: Equatable {
    var macros: [BCDMacro] = []
    var stepMillis = BCDMacroSettings.defaultStep

    static let slots = 3
    static let maxSteps = 12
    static let defaultStep = 60
    static let stepChoices = [30, 60, 100, 150, 250]
    static let stepRange = 20...500
    static let lineNames: [String] = (1...slots).flatMap { ["macro\($0)-button", "macro\($0)-mode", "macro\($0)-steps"] } + ["macro-step"]

    var isOn: Bool { !macros.isEmpty }

    static func parse(_ get: (String) -> String?) -> BCDMacroSettings {
        var s = BCDMacroSettings()
        if let text = get("macro-step")?.trimmingCharacters(in: .whitespaces), let v = Int(text) {
            s.stepMillis = min(max(v, stepRange.lowerBound), stepRange.upperBound)
        }
        for n in 1...slots {
            guard let button = BCDPadInput.named(get("macro\(n)-button") ?? ""), BCDPadInput.main.contains(button) else { continue }
            let mode = BCDMacro.Mode(rawValue: (get("macro\(n)-mode") ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .once
            let steps = parseSteps(get("macro\(n)-steps") ?? "")
            guard steps.contains(where: { !$0.isEmpty }) else { continue }
            s.macros.append(BCDMacro(trigger: button, mode: mode, steps: steps, stepMillis: s.stepMillis))
        }
        return s
    }

    /// "a, a, lb+a, -": a chord is names joined by +, "-" or "wait" is a pause; a step with a name this build does not know is
    /// dropped; no more than `maxSteps`.
    static func parseSteps(_ text: String) -> [[BCDPadInput]] {
        var out: [[BCDPadInput]] = []
        for token in text.lowercased().split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let word = token.trimmingCharacters(in: .whitespaces)
            if word == "-" || word == "wait" || word.isEmpty {
                out.append([])
            } else {
                let inputs = word.split(separator: "+").compactMap { BCDPadInput.named(String($0)) }
                let names = word.split(separator: "+").count
                guard inputs.count == names, !inputs.isEmpty else { continue }
                var chord: [BCDPadInput] = []
                for input in inputs where !chord.contains(input) { chord.append(input) }
                out.append(chord)
            }
            if out.count == maxSteps { break }
        }
        return out
    }

    /// The text `parseSteps` reads back to the same steps.
    static func stepsText(_ steps: [[BCDPadInput]]) -> String {
        steps.map { $0.isEmpty ? "-" : $0.map(\.rawValue).joined(separator: "+") }.joined(separator: ", ")
    }
}

/// Plays the macros: remembers which button was down at the last sample and where each run is.
struct BCDMacroPlayer {
    private var wasDown: [Int: Bool] = [:]
    private var started: [Int: UInt64] = [:]
    private var holding: Set<Int> = []

    struct Result: Equatable {
        /// The buttons that belong to a macro: the game does not see them as pressed.
        var swallowed: [BCDPadInput] = []
        /// What the macros press now.
        var add = BCDPadBits()
        /// A run is going: the caller keeps sampling.
        var active = false
    }

    /// `raw` is the controller as the player holds it.
    mutating func process(_ macros: [BCDMacro], raw: BCDPadBits, now: UInt64) -> Result {
        var result = Result()
        for (i, macro) in macros.enumerated() {
            let down = raw.holds(macro.trigger)
            let was = wasDown[i] ?? false
            wasDown[i] = down
            result.swallowed.append(macro.trigger)
            guard macro.total > 0 else { continue }
            switch macro.mode {
            case .once:
                if down && !was && started[i] == nil { started[i] = now }
                if let t0 = started[i] {
                    let e = Int(clamping: now &- t0)
                    if e >= macro.total {
                        started[i] = nil
                    } else {
                        result.add.add(macro.output(at: e))
                        result.active = true
                    }
                }
            case .repeating:
                if down {
                    let t0 = started[i] ?? now
                    started[i] = t0
                    result.add.add(macro.output(at: Int(clamping: now &- t0) % macro.total))
                    result.active = true
                } else {
                    started[i] = nil
                }
            case .hold:
                if down && !was {
                    if holding.contains(i) { holding.remove(i) } else { holding.insert(i) }
                }
                if holding.contains(i) { result.add.add(macro.held) }
            }
        }
        return result
    }

    mutating func reset() {
        wasDown.removeAll()
        started.removeAll()
        holding.removeAll()
    }
}

// MARK: - Presses made by BCD itself (the radial menu's controller slots)

/// A press the app makes on the controller for a moment: it is added to what the player holds.
struct BCDPadInjector {
    private var items: [(bits: BCDPadBits, until: UInt64)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func inject(_ bits: BCDPadBits, now: UInt64, millis: Int) {
        items.append((bits, now &+ UInt64(max(1, millis))))
    }

    /// Adds the live presses to `bits`; true while one is still live.
    mutating func process(_ bits: inout BCDPadBits, now: UInt64) -> Bool {
        items.removeAll { $0.until <= now }
        for item in items { bits.add(item.bits) }
        return !items.isEmpty
    }

    mutating func reset() { items.removeAll() }
}

// MARK: - Everything for player 1's sample

/// Turbo, macros and injected presses in one pass over the controller's state.
struct BCDPadExtras {
    private(set) var turbo = BCDTurboSettings()
    private(set) var macros = BCDMacroSettings()
    private var gate = BCDTurboGate()
    private var player = BCDMacroPlayer()
    private var injector = BCDPadInjector()

    /// The sample hook has work: a turbo input or a macro is set, or a press is being made.
    var needsSample: Bool { turbo.padOn || macros.isOn || !injector.isEmpty }
    /// The settings alone need the controller (the hook is gated on this).
    var configured: Bool { turbo.padOn || macros.isOn }

    mutating func configure(turbo: BCDTurboSettings, macros: BCDMacroSettings) {
        if turbo != self.turbo { gate.reset() }
        if macros != self.macros { player.reset() }
        self.turbo = turbo
        self.macros = macros
    }

    mutating func inject(_ bits: BCDPadBits, now: UInt64, millis: Int) { injector.inject(bits, now: now, millis: millis) }

    mutating func reset() {
        gate.reset()
        player.reset()
        injector.reset()
    }

    /// Changes `bits` as the game should see them; true while the caller should sample again soon (an input is held for
    /// turbo, a run is playing, or a press is being made).
    mutating func process(_ bits: inout BCDPadBits, now: UInt64) -> Bool {
        let raw = bits
        var again = false
        if turbo.padOn { again = gate.apply(turbo, &bits, now: now) || again }
        if macros.isOn {
            let result = player.process(macros.macros, raw: raw, now: now)
            result.swallowed.forEach { bits.clear($0) }
            bits.add(result.add)
            again = result.active || again
        }
        again = injector.process(&bits, now: now) || again
        return again
    }
}

// MARK: - Turbo on the touch controls' keys and mouse buttons

/// Repeats a key or mouse button of a touch control while the finger stays on it. The first press goes
/// through as it is; the repeats are the ops `tick` returns.
struct BCDKeyTurbo {
    enum Target: Hashable { case key(Int32), mouseLeft, mouseRight }
    struct Op: Equatable {
        var target: Target
        var down: Bool
    }
    private struct Held {
        var since: UInt64
        var refs: Int
        var down: Bool
    }
    private var held: [Target: Held] = [:]

    var isActive: Bool { !held.isEmpty }

    /// A control with this target went down; the original press goes on.
    mutating func press(_ target: Target, now: UInt64) {
        if var h = held[target] {
            h.refs += 1
            held[target] = h
        } else {
            held[target] = Held(since: now, refs: 1, down: true)
        }
    }

    /// A control with this target lifted. True when the original release should go on: the target is down right now, so the
    /// game must see it come up. False when the last control lifted while the target was in its up half (it is already up).
    mutating func release(_ target: Target) -> Bool {
        guard var h = held[target] else { return true }
        h.refs -= 1
        if h.refs > 0 {
            held[target] = h
            return false
        }
        held[target] = nil
        return h.down
    }

    /// The flips due at `now`.
    mutating func tick(now: UInt64, rate: Int) -> [Op] {
        var ops: [Op] = []
        for (target, h) in held {
            let want = BCDTurboClock.isDown(elapsed: Int(clamping: now &- h.since), rate: rate)
            if want != h.down {
                held[target]?.down = want
                ops.append(Op(target: target, down: want))
            }
        }
        return ops.sorted { "\($0.target)" < "\($1.target)" }
    }

    /// Everything lifts (the session ends): the targets that are down need an up.
    mutating func releaseAll() -> [Op] {
        let ops = held.filter { $0.value.down }.map { Op(target: $0.key, down: false) }
        held.removeAll()
        return ops.sorted { "\($0.target)" < "\($1.target)" }
    }
}
