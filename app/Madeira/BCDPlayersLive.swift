// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
// GameController supports background handler queues but lacks Sendable annotations.
@preconcurrency import GameController
import UIKit

// Players on the engine (round 604; BCDPlayers.swift has the rules, BCDPlayersViews.swift the card).
//
// Where a controller goes. GamepadInput gives each controller that connects the first free slot of four. With a remembered choice
// (BCDPlayerSettings.assigned) a controller goes to the slot it was chosen for when that is free; with none, nothing changes.
// A choice is made by pressing a button on the controller ("Player 2: press a button"): while that waits, GamepadInput.sample
// looks at the pads' buttons (one static flag, -1 while nobody is choosing), and the first pad pressed takes the slot, changing
// places with the pad that had it.
//
// Rumble per player is PadOutput.m's per-slot factor. The touch controls play as the slot chosen (Player 1 unless changed).
//
// Cost. Off (nothing chosen): two static reads in GamepadInput (the choosing flag, the touch slot), and a lookup when a controller
// connects. Nothing runs on a timer. Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

@MainActor final class BCDPlayersLive: BCDPlayersActions {
    static let shared = BCDPlayersLive()

    /// The slot being chosen for, -1 when nobody is choosing. Read on GamepadInput's queue.
    nonisolated(unsafe) static var listening = -1
    /// The slot the touch controls play as. Read on GamepadInput's queue.
    nonisolated(unsafe) static var touchSlot = BCDPlayersLive.stored().touchSlot

    // MARK: Settings

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var current = BCDPlayersLive.stored()

    nonisolated static func stored() -> BCDPlayerSettings {
        let lines = BCDInputPrefs.shared.lines(BCDInputLines.players, game: BCDInputPrefs.everyone)
        return BCDPlayerSettings.parse { lines[$0] }
    }

    nonisolated static func settings() -> BCDPlayerSettings {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Reads the choices again (after one is written) and tells everything that depends on them.
    func reload() {
        let now = Self.stored()
        Self.lock.lock()
        Self.current = now
        Self.lock.unlock()
        Self.touchSlot = now.touchSlot
        for slot in 0..<BCDPlayerSlots.count { madeira_pad_output_set_scale(Int32(slot), now.rumbleScale(slot)) }
        GamepadInput.shared.inputExtrasChanged()
        show(lastNames)
    }

    // MARK: Who is in which slot

    nonisolated static func name(of controller: GCController) -> String {
        let vendor = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return vendor.isEmpty ? "Controller" : vendor
    }

    /// The key each connected controller is remembered by (main thread: GameController's list in its own order).
    static func keys(for list: [GCController]) -> [ObjectIdentifier: String] {
        var seen: [String: Int] = [:]
        var out: [ObjectIdentifier: String] = [:]
        for controller in list {
            let base = BCDPlayerSlots.deviceKey(vendor: name(of: controller), category: controller.productCategory, ordinal: 0)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            out[ObjectIdentifier(controller)] = BCDPlayerSlots.deviceKey(vendor: name(of: controller), category: controller.productCategory, ordinal: n)
        }
        return out
    }

    /// The slot a connecting controller takes (GamepadInput.refreshControllers, on its queue): the one it was chosen for if that is free,
    /// else the first free one, which is what it always was.
    nonisolated static func slot(forKey key: String?, occupied: [Bool]) -> Int? {
        let s = settings()
        guard let key, !s.assigned.isEmpty else { return occupied.firstIndex(of: false) }
        return BCDPlayerSlots.choose(preferred: s.preferredSlots(for: key), occupied: occupied)
    }

    // MARK: Choosing (the queue sees the press; the main thread keeps the choice)

    private var timeout: DispatchWorkItem?
    private var lastNames: [String?] = []
    /// Buttons already held when choosing began are not a choice; this turns false once every pad has been let go.
    nonisolated(unsafe) private static var waitingForRelease = true

    func beginAssign(slot: Int) {
        guard (0..<BCDPlayerSlots.count).contains(slot), GamepadInput.enabled else { return }
        Self.waitingForRelease = true
        Self.listening = slot
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.cancelAssign() }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
        LogStore.shared.log("[players] \(BCDPlayerSlots.title(slot)): waiting for a button on the controller")
        show(lastNames)
        GamepadInput.shared.inputExtrasChanged()
    }

    func cancelAssign() {
        timeout?.cancel()
        timeout = nil
        guard Self.listening >= 0 else { return }
        Self.listening = -1
        LogStore.shared.log("[players] choosing a controller ended with no choice")
        show(lastNames)
    }

    /// The pad (its index in `pads`) with a button down, once every pad has been let go since choosing began. Called on GamepadInput's queue.
    nonisolated static func pressed(in pads: [GCExtendedGamepad?]) -> Int? {
        func held(_ pad: GCExtendedGamepad) -> Bool {
            let buttons: [GCControllerButtonInput?] = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder,
                                                       pad.buttonMenu, pad.buttonOptions, pad.leftThumbstickButton, pad.rightThumbstickButton,
                                                       pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right]
            return buttons.contains { $0?.isPressed == true } || pad.leftTrigger.value > 0.5 || pad.rightTrigger.value > 0.5
        }
        let down = pads.indices.filter { pads[$0].map(held) ?? false }
        if waitingForRelease {
            if down.isEmpty { waitingForRelease = false }
            return nil
        }
        return down.first
    }

    /// A controller took `slot` (GamepadInput's queue has moved it): remember it and the one it changed places with.
    nonisolated static func chose(_ controller: GCController, displaced: GCController?, from: Int, to slot: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { BCDPlayersLive.shared.remember(controller, displaced: displaced, from: from, to: slot) }
        }
    }

    private func remember(_ controller: GCController, displaced: GCController?, from: Int, to slot: Int) {
        timeout?.cancel()
        timeout = nil
        let keys = Self.keys(for: GCController.controllers())
        guard let key = keys[ObjectIdentifier(controller)] else { return }
        var s = Self.stored()
        let moved = BCDPlayerSlots.assigning(s.assigned, key: key, to: slot, left: from, displaced: displaced.flatMap { keys[ObjectIdentifier($0)] })
        s.assigned = moved
        for n in 0..<BCDPlayerSlots.count {
            BCDInputPrefs.shared.set(BCDInputLines.players, game: BCDInputPrefs.everyone, line: "p\(n + 1)-pad", value: moved[n] ?? "")
        }
        LogStore.shared.log("[players] \(BCDPlayerSlots.title(slot)): \(Self.name(of: controller))"
                            + (displaced.map { ", \(Self.name(of: $0)) is \(BCDPlayerSlots.title(from)) now" } ?? ""))
        reload()
    }

    // MARK: What the screens show

    nonisolated static func report(_ controllers: [GCController?]) {
        let names = controllers.map { $0.map(name(of:)) }
        DispatchQueue.main.async { MainActor.assumeIsolated { BCDPlayersLive.shared.show(names) } }
    }

    private func show(_ names: [String?]) {
        lastNames = names
        let model = BCDPlayersModel.shared
        model.actions = self
        model.update(names: names, settings: Self.settings(), listening: Self.listening >= 0 ? Self.listening : nil)
    }

    // MARK: Asked by the screens

    func setRumble(slot: Int, percent: Int) {
        BCDInputLive.shared.write(setting: "p\(slot + 1)-rumble", value: String(percent), windowsPath: BCDInputPrefs.everyone)
    }

    func setTouchPlayer(slot: Int) {
        BCDInputLive.shared.write(setting: "touch-player", value: String(slot + 1), windowsPath: BCDInputPrefs.everyone)
    }

    func reset() {
        cancelAssign()
        for line in BCDPlayerSettings.lineNames { BCDInputPrefs.shared.set(BCDInputLines.players, game: BCDInputPrefs.everyone, line: line, value: "") }
        LogStore.shared.log("[players] back to first come, first served")
        reload()
    }
}

// MARK: - GamepadInput's side

extension GamepadInput {
    /// The pad with a button down takes the slot being chosen for and changes places with the pad that had it. On `queue`, from `sample()`.
    func assignListened(_ i: Int) {
        let j = BCDPlayersLive.listening
        BCDPlayersLive.listening = -1
        guard controllers.indices.contains(i), controllers.indices.contains(j), let moved = controllers[i] else { return }
        let displaced = i == j ? nil : controllers[j]
        if i != j {
            controllers.swapAt(i, j)
            profiles.swapAt(i, j)
            // Each slot starts still, as when a pad joins it, and its rumble plays on the pad now in it.
            for slot in [i, j] {
                winios_gamepad_set_vibration(Int32(slot), 0, 0)
                madeira_pad_output_set_slot(Int32(slot), controllers[slot])
            }
            updateTimer()
        }
        BCDPlayersLive.chose(moved, displaced: displaced, from: i, to: j)
        BCDPlayersLive.report(controllers)
    }
}

/// The in-game menu's rows for the players' page: choosing a controller, cancelling, and starting over.
@MainActor enum BCDPlayersMenuLive {
    /// True when `row` was one of them.
    static func act(_ row: String) -> Bool {
        if row.hasPrefix(BCDInputMenu.assignRow), let slot = Int(row.dropFirst(BCDInputMenu.assignRow.count)) {
            if BCDPlayersLive.listening == slot { BCDPlayersLive.shared.cancelAssign() } else { BCDPlayersLive.shared.beginAssign(slot: slot) }
            return true
        }
        switch row {
        case BCDInputMenu.cancelRow: BCDPlayersLive.shared.cancelAssign(); return true
        case BCDInputMenu.resetRow: BCDPlayersLive.shared.reset(); return true
        default: return false
        }
    }
}
