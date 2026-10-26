// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Turbo and macros on the engine (round 604; BCDTurbo.swift has the rules).
//
// Cost. Nothing exists until a game whose player turned turbo or a macro on is played: GamepadInput reads one static
// flag (`padNeeded`, false), BCDTouchLive.send reads another (`touchNeeded`, false). Turned on, the controller hook runs
// where the controller's state is built (a few comparisons), and a timer exists only while a turbo input is held, a macro
// is playing or BCD is making a press itself; it stops by itself the moment none of those is true. The touch controls'
// key repeat has its own timer, alive only while a finger holds a repeating key or mouse button.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

final class BCDTurboLive: @unchecked Sendable {
    static let shared = BCDTurboLive()

    /// GamepadInput's sample hook has work (a turbo input or a macro is set, or a press is being made).
    nonisolated(unsafe) static var padNeeded = false
    /// BCDTouchLive.send hands its key and mouse events to `passes`.
    nonisolated(unsafe) static var touchNeeded = false

    /// Milliseconds on a clock that does not jump.
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    // MARK: Controller (GamepadInput's queue; the lock guards what the main thread configures)

    private let lock = NSLock()
    private var extras = BCDPadExtras()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "bcd.turbo", qos: .userInteractive)
    private var title = ""

    /// Player 1's controller as the game is about to see it, merged touch and physical.
    func padSample(_ state: inout winios_gamepad) {
        var bits = BCDPadBits(buttons: state.buttons, lt: state.left_trigger, rt: state.right_trigger)
        lock.lock()
        let again = extras.process(&bits, now: Self.now())
        let work = extras.needsSample
        lock.unlock()
        state.buttons = bits.buttons
        state.left_trigger = bits.lt
        state.right_trigger = bits.rt
        setTimer(again)
        if !work { Self.padNeeded = false }
    }

    /// While `on`, the controller is sampled every 5 ms (a turbo input's half period is at least 16 ms).
    private func setTimer(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if on, timer == nil {
            let source = DispatchSource.makeTimerSource(queue: timerQueue)
            source.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
            source.setEventHandler { GamepadInput.shared.inputExtrasChanged() }
            timer = source
            source.resume()
        } else if !on, let source = timer {
            source.cancel()
            timer = nil
        }
    }

    /// BCD presses a button of player 1's controller for a moment (the radial menu's controller slots).
    func inject(_ input: BCDPadInput, millis: Int = 70) {
        var bits = BCDPadBits()
        bits.press(input)
        lock.lock()
        extras.inject(bits, now: Self.now(), millis: millis)
        lock.unlock()
        Self.padNeeded = true
        GamepadInput.shared.inputExtrasChanged()
    }

    // MARK: Settings (main thread)

    private var touchSettings = BCDTurboSettings()
    private var keyTurbo = BCDKeyTurbo()
    private var touchTimer: DispatchSourceTimer?
    private var lastNote = ""

    @MainActor func configure(turbo: BCDTurboSettings, macros: BCDMacroSettings, title: String) {
        lock.lock()
        extras.configure(turbo: turbo, macros: macros)
        if title.isEmpty { extras.reset() }   // no game is running
        let configured = extras.needsSample
        lock.unlock()
        self.title = title
        Self.padNeeded = configured
        touchSettings = turbo
        Self.touchNeeded = turbo.touchOn
        if !turbo.touchOn { releaseKeys() }
        if !configured { setTimer(false) }
        let note = turbo.isOn || macros.isOn
            ? "\(title): turbo [\(turbo.line)] keys [\(BCDKeyNames.listText(turbo.keys))] \(turbo.rate) a second, \(macros.macros.count) macro(s)" : ""
        if note != lastNote {
            lastNote = note
            if !note.isEmpty { LogStore.shared.log("[turbo] " + note) }
        }
        GamepadInput.shared.inputExtrasChanged()
    }

    // MARK: The touch controls' keys and mouse buttons (main thread)

    /// Whether a touch control's event goes to the game as it is. A repeating key or mouse button goes down at once, then the
    /// repeats come from the timer; its lift goes on only when the game must see it come up.
    @MainActor func passes(_ event: BCDTouchEvent) -> Bool {
        guard let (target, down) = Self.target(of: event), repeats(target) else { return true }
        if down {
            keyTurbo.press(target, now: Self.now())
            startTouchTimer()
            return true
        }
        let pass = keyTurbo.release(target)
        if !keyTurbo.isActive { stopTouchTimer() }
        return pass
    }

    private func repeats(_ target: BCDKeyTurbo.Target) -> Bool {
        switch target {
        case .key(let vk): return touchSettings.keys.contains(vk)
        case .mouseLeft: return touchSettings.mouseLeft
        case .mouseRight: return touchSettings.mouseRight
        }
    }

    private static func target(of event: BCDTouchEvent) -> (BCDKeyTurbo.Target, Bool)? {
        switch event {
        case .key(let vk, let down): return (.key(vk), down)
        case .mouse(let flags):
            switch flags {
            case BCDTouchEvent.leftDown: return (.mouseLeft, true)
            case BCDTouchEvent.leftUp: return (.mouseLeft, false)
            case BCDTouchEvent.rightDown: return (.mouseRight, true)
            case BCDTouchEvent.rightUp: return (.mouseRight, false)
            default: return nil
            }
        case .toggleKeyboard: return nil
        }
    }

    @MainActor private func startTouchTimer() {
        guard touchTimer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tickTouch() }
        }
        touchTimer = source
        source.resume()
    }

    @MainActor private func stopTouchTimer() {
        touchTimer?.cancel()
        touchTimer = nil
    }

    @MainActor private func tickTouch() {
        for op in keyTurbo.tick(now: Self.now(), rate: touchSettings.rate) { post(op) }
    }

    private func post(_ op: BCDKeyTurbo.Op) {
        switch op.target {
        case .key(let vk): winios_post_key(vk, op.down ? 1 : 0)
        case .mouseLeft: winios_pointer(0, 0, op.down ? BCDTouchEvent.leftDown : BCDTouchEvent.leftUp, 0)
        case .mouseRight: winios_pointer(0, 0, op.down ? BCDTouchEvent.rightDown : BCDTouchEvent.rightUp, 0)
        }
    }

    /// The session ends, the settings change or the app leaves the foreground: what is down comes up.
    @MainActor func releaseKeys() {
        stopTouchTimer()
        for op in keyTurbo.releaseAll() { post(op) }
    }
}
