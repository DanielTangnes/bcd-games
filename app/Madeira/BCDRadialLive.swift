// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Combine
import Foundation
import SwiftUI
import UIKit

// The radial menu on the engine (round 604; BCDRadial.swift has the rules, BCDRadialViews.swift draws it) and the one place the
// things BCD can do for a game are carried out (BCDInputAction: a key, a combination, a click, the wheel, BCD's menu, the iOS keyboard,
// the key bar, a press of the controller). The touch gestures use the same runner.
//
// Cost. Nothing exists until a game whose player turned the ring on is played: the window is made then and dropped when the game ends,
// the setting goes off, or the in-game menu covers it (it steps aside as the key bar does). The ring is drawn when it opens and when the
// finger changes slot; no timer, no polling. Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

/// Carries out an action of BCDInputAction.
@MainActor enum BCDInputActionRunner {
    static func run(_ action: BCDInputAction) {
        if let steps = action.keySteps {
            BCDKeySender.post(steps)
            return
        }
        if let steps = action.mouseSteps {
            for step in steps {
                if step.delay <= 0 {
                    winios_pointer(0, 0, step.flags, UInt32(bitPattern: step.data))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(step.delay)) { winios_pointer(0, 0, step.flags, UInt32(bitPattern: step.data)) }
                }
            }
            return
        }
        switch action {
        case .menu: LibraryModel.shared.showMenu()
        case .keyboard: MetalBackedView.toggleKeyboard()
        case .keyBar: BCDExtraKeysHost.shared.toggle()
        case .pad(let input): BCDTurboLive.shared.inject(input)
        case .key, .chord, .click, .wheel: break
        }
    }
}

/// The ring's window: above the game, the touch controls, the keyboard and the key bar, taking a touch only where the button is (the
/// whole screen while the ring is open).
final class BCDRadialWindow: UIWindow {
    var hitRect = CGRect.zero
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard hitRect.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor final class BCDRadialHost {
    static let shared = BCDRadialHost()

    private var window: BCDRadialWindow?
    private let model = BCDRadialModel()
    private var watchers = Set<AnyCancellable>()
    private var wanted = BCDRadialSettings()

    var visible: Bool { window != nil }

    /// The running game's choices (BCDInputLive.refresh): the ring appears for a game that turned it on and is being played.
    func configure(_ settings: BCDRadialSettings, running: Bool, title: String) {
        let on = settings.isOn && running
        if on {
            wanted = settings
            model.settings = settings
            model.choose = { BCDInputActionRunner.run($0) }
            if window == nil { show(title: title) }
            sessionChanged()
        } else if window != nil {
            hide()
        }
    }

    private func show(title: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = BCDRadialWindow(windowScene: scene)
        w.windowLevel = .normal + 104   // over the key bar (+103), the keyboard (+102) and the touch controls (+101)
        w.backgroundColor = .clear
        let root = BCDRadialLayer(model: model, report: { [weak w] in w?.hitRect = $0 })
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        w.rootViewController = controller
        w.isHidden = false   // never made key: the game keeps the keyboard focus
        window = w
        watch()
        LogStore.shared.log("[radial] \(title): the radial menu is on (\(wanted.filled.count) slots)")
    }

    private func hide() {
        model.cancel()
        window?.isHidden = true
        window = nil
        watchers.removeAll()
    }

    /// Steps aside for the in-game menu and the starting screen; lets go of a finger when the app leaves.
    private func watch() {
        let library = LibraryModel.shared
        watchers.removeAll()
        Publishers.Merge(library.$menu.map { _ in () }, library.$launching.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sessionChanged() }
            .store(in: &watchers)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.model.cancel() }
            .store(in: &watchers)
    }

    private func sessionChanged() {
        let library = LibraryModel.shared
        let covered = library.menu || library.launching
        if covered { model.cancel() }
        window?.isHidden = covered
    }
}
