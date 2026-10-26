// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Combine
import Foundation
import SwiftUI
import UIKit

// The magnifier on the engine (round 604, B4). BCDMagnifier.swift is the geometry; MetalBackedView reads BCDMagnifierCurrent.state when it
// places the presented layer (gameRect) and when it maps a touch (mapPoint), so the enlarged picture and the finger always agree. This file
// holds the player's choices, asks the view to lay out again when they change, and owns the bar's window.
//
// Cost: at 1x, the default, nothing here exists beyond one stored value. The bar's window is made when the magnifier is switched on and
// dropped when it goes off, the menu opens or the session ends. Enlarging is the compositor's work (the layer is given a larger frame):
// the game renders and presents exactly as before.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

final class BCDMagnifierWindow: UIWindow {
    var hitRect = CGRect.zero
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard hitRect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor final class BCDMagnifierLive {
    static let shared = BCDMagnifierLive()

    private var window: BCDMagnifierWindow?
    private let bar = BCDMagnifierBarModel()
    private var watchers = Set<AnyCancellable>()

    var state: BCDMagnifierState { BCDMagnifierCurrent.state }
    var isOn: Bool { state.isOn }

    /// The zoom the menu's chips set (one of BCDMagnifierState.zooms; 1 is off).
    func setZoom(_ value: Double) {
        let was = isOn
        publish(state.zoomed(to: BCDMagnifierState.nearestZoom(value)))
        if isOn && !was { showBar(); LogStore.shared.log("[magnifier] on: \(state.words)") }
        if !isOn && was { hideBar(); LogStore.shared.log("[magnifier] off") }
    }

    /// The bar's plus and minus: the next zoom up or down.
    private func step(_ direction: Int) {
        let zooms = BCDMagnifierState.zooms
        guard let i = zooms.firstIndex(of: BCDMagnifierState.nearestZoom(state.zoom)) else { return }
        setZoom(zooms[min(max(i + direction, 0), zooms.count - 1)])
    }

    /// An arrow of the bar: `dx` and `dy` are -1, 0 or 1 steps of the visible part.
    private func pan(_ dx: Double, _ dy: Double) {
        publish(state.panned(dx: dx * BCDMagnifierState.panStep, dy: dy * BCDMagnifierState.panStep))
    }

    /// The menu's chips and the bar share one state; the view lays out again.
    private func publish(_ next: BCDMagnifierState) {
        guard next != BCDMagnifierCurrent.state else { return }
        BCDMagnifierCurrent.state = next
        bar.state = next
        MetalBackedView.refreshDisplayMode(reason: "magnifier")
    }

    /// The session ended (or a new one began): back to 1x without a word.
    func reset() {
        let was = isOn
        hideBar()
        if BCDMagnifierCurrent.state != BCDMagnifierState() {
            BCDMagnifierCurrent.state = BCDMagnifierState()
            bar.state = BCDMagnifierState()
            if was { MetalBackedView.refreshDisplayMode(reason: "magnifier-reset") }
        }
    }

    // MARK: The bar's window

    func showBar() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = BCDMagnifierWindow(windowScene: scene)
        w.windowLevel = .normal + 103   // over the keyboard window (+102) and the touch controls (+101)
        w.backgroundColor = .clear
        bar.state = state
        let root = BCDMagnifierBarLayer(model: bar,
                                        zoom: { [weak self] in self?.step($0) },
                                        pan: { [weak self] in self?.pan($0, $1) },
                                        close: { [weak self] in self?.setZoom(1) },
                                        report: { [weak w] in w?.hitRect = $0 })
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        w.rootViewController = controller
        w.isHidden = LibraryModel.shared.menu   // never made key: the game keeps the keyboard focus
        window = w
        // The bar goes with the session and steps aside for the menu.
        let library = LibraryModel.shared
        Publishers.Merge(library.$current.map { _ in () }, library.$menu.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                if LibraryModel.shared.current == nil { self.reset(); return }
                self.window?.isHidden = LibraryModel.shared.menu
            }
            .store(in: &watchers)
    }

    private func hideBar() {
        window?.isHidden = true
        window = nil
        watchers.removeAll()
    }
}
