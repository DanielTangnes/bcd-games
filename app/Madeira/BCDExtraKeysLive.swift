// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Combine
import Foundation
import SwiftUI
import UIKit

// The extra keys on the engine (round 603): BCDExtraKeys.swift decides what a key presses and in
// which order, BCDExtraKeyBar.swift draws the bar; this file posts the keys, through
// winios_post_key like every other key of the app, and holds the bar's window.
//
// Cost: nothing exists until the player opens the bar from the in-game menu (or presses a key of
// the keyboard bar's second page); the window is made then and dropped when the bar closes, the
// menu opens or the session ends. A key sends a few posts and a couple of timers; nothing polls.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

/// Posts key steps (BCDKeyStep) to the game: the ones due now at once, in order, the rest when
/// their time comes, one block per time so the order within a time never depends on the queue.
@MainActor enum BCDKeySender {
    static func post(_ steps: [BCDKeyStep]) {
        guard !steps.isEmpty else { return }
        let times = Set(steps.map(\.delay)).sorted()
        for time in times {
            let group = steps.filter { $0.delay == time }
            if time <= 0 {
                for step in group { winios_post_key(step.vk, step.down ? 1 : 0) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(time)) {
                    for step in group { winios_post_key(step.vk, step.down ? 1 : 0) }
                }
            }
        }
    }

    /// An action of the keyboard bar's second page, with the modifiers its latches hold down
    /// (`held`: they are real key-downs already, so the chord leaves them alone).
    static func send(_ action: BCDExtraKeyAction, held: Set<Int32>) {
        post(BCDExtraKeys.steps(action, held: held))
    }
}

/// The key bar's window: above the game, the touch controls and the keyboard's own window, taking
/// a touch only where the bar is.
final class BCDExtraKeysWindow: UIWindow {
    var hitRect = CGRect.zero
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard hitRect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor final class BCDExtraKeysHost {
    static let shared = BCDExtraKeysHost()

    private var window: BCDExtraKeysWindow?
    private let model = BCDExtraKeyBarModel()
    private var latches = BCDModifierLatches()
    private var watchers = Set<AnyCancellable>()
    /// The bar was opened in a library session: it goes when that session does. A bar opened in a
    /// session without a library entry (the touch-controls window's own menu) stays until closed.
    private var followsLibrarySession = false

    var visible: Bool { window != nil }

    func toggle() { visible ? hide() : show() }

    func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = BCDExtraKeysWindow(windowScene: scene)
        w.windowLevel = .normal + 103   // over the keyboard window (+102) and the touch controls (+101)
        w.backgroundColor = .clear
        let root = BCDExtraKeyBarLayer(model: model,
                                       press: { [weak self] in self?.press($0) },
                                       longPress: { [weak self] in self?.longPress($0) },
                                       close: { [weak self] in self?.hide() },
                                       report: { [weak w] in w?.hitRect = $0 })
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        w.rootViewController = controller
        w.isHidden = false   // never made key: the game keeps the keyboard focus
        window = w
        followsLibrarySession = LibraryModel.shared.current != nil
        watch()
        w.isHidden = LibraryModel.shared.menu
        LogStore.shared.log("[keybar] shown")
    }

    func hide() {
        guard let w = window else { return }
        BCDKeySender.post(latches.releaseAll())
        model.states = latches.states
        w.isHidden = true
        window = nil
        watchers.removeAll()
        LogStore.shared.log("[keybar] hidden")
    }

    /// Goes with the session, steps aside for the menu, lets the modifiers go when the app leaves.
    private func watch() {
        let library = LibraryModel.shared
        Publishers.Merge3(library.$current.map { _ in () }, library.$menu.map { _ in () }, library.$launching.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sessionChanged() }
            .store(in: &watchers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.releaseLatches() }
            .store(in: &watchers)
    }

    private func sessionChanged() {
        let library = LibraryModel.shared
        if followsLibrarySession, library.current == nil { hide(); return }
        let covered = library.menu || library.launching
        if covered, window?.isHidden == false { releaseLatches() }
        window?.isHidden = covered
    }

    private func releaseLatches() {
        guard !latches.isEmpty else { return }
        BCDKeySender.post(latches.releaseAll())
        model.states = latches.states
    }

    private func press(_ key: BCDExtraKey) {
        if let vk = key.modifierCode {
            BCDKeySender.post(latches.tap(vk))
        } else {
            let steps = BCDExtraKeys.steps(key.action, held: latches.held)
            let after = BCDModifierLatches.duration(steps) + BCDExtraKeys.modifierTail
            BCDKeySender.post(steps + latches.keyPressed(after: after))
        }
        model.states = latches.states
    }

    private func longPress(_ key: BCDExtraKey) {
        guard let vk = key.modifierCode else { return }
        BCDKeySender.post(latches.longPress(vk))
        model.states = latches.states
    }
}

/// The in-game menu's row for the key bar (Game › Key bar), in both menus.
@MainActor enum BCDExtraKeysMenu {
    static let rowID = "keybar"

    static func row() -> BCDMenuRow {
        let open = BCDExtraKeysHost.shared.visible
        return BCDMenuRow(id: rowID, title: open ? "Hide the key bar" : "Key bar",
                          detail: "Esc, Tab, Alt+Tab, Alt+Enter, Win, Del, F1 to F12 and Ctrl, Alt and Shift as latches, in a bar you can move.",
                          symbol: "keyboard.badge.ellipsis", kind: .action())
    }
}
