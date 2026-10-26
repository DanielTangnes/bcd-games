// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Combine
import Foundation
import UIKit

// What the touch controls do when nobody touches them (round 604, B10): after a time the player chose, with no finger on a control, the
// controls go, and the first touch on the game brings them back. While they are gone they do not exist: the overlay builds no view for
// them, the window's hit test gives every touch to the game, and nothing is drawn or timed. With the choice at "Never", which is how
// every session starts, no timer is ever made and no touch is looked at beyond one comparison.
//
// BCDTouchFeelModel also carries the colour revision: the controls are drawn again when the player changes their colour (the views
// compare equal to themselves otherwise, which is what keeps them cheap).
//
// No engine type here: ContentView's overlay and the controls' window call it, BCDSessionFeelLive sets it. Main thread.

@MainActor final class BCDTouchFeelModel: ObservableObject {
    static let shared = BCDTouchFeelModel()

    /// The controls are hidden for want of a touch. Mirrored in BCDTouchFeel.controlsHidden for the window's hit test.
    @Published private(set) var hidden = false
    /// Changes whenever the controls have to be drawn again (their colour).
    @Published private(set) var revision = 0

    /// Seconds without a finger on a control after which they hide; 0 is never.
    private(set) var seconds = 0
    private var timer: Timer?
    /// How many fingers are on a control right now.
    private var held = 0
    /// Something stands over the controls (the menu, the editor): they are not timed then.
    private(set) var suspended = false

    func configure(seconds: Int) {
        let clean = BCDHideAfter.clamp(seconds) ?? 0
        self.seconds = clean
        if clean == 0 { showAndStop() } else { arm() }
    }

    func colorChanged() { revision &+= 1 }

    /// The menu or the editor opens (true) or goes (false).
    func setSuspended(_ now: Bool) {
        guard now != suspended else { return }
        suspended = now
        if now { timer?.invalidate(); timer = nil; setHidden(false) } else { arm() }
    }

    /// From the controls' window: a touch event on a control. `fingers` is how many touches of the event are still down.
    func controlsTouched(fingers: Int) {
        guard seconds > 0 else { return }
        held = fingers
        if fingers > 0 { timer?.invalidate(); timer = nil } else { arm() }
    }

    /// From the game view: a finger came down where no control is. Brings the controls back.
    func gameTouched() {
        guard seconds > 0, hidden else { return }
        setHidden(false)
        arm()
    }

    func reset() {
        seconds = 0
        held = 0
        suspended = false
        showAndStop()
    }

    private func showAndStop() {
        timer?.invalidate()
        timer = nil
        setHidden(false)
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard seconds > 0, !hidden, !suspended, held == 0 else { return }
        let t = Timer(timeInterval: Double(seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timeUp() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func timeUp() {
        timer = nil
        guard seconds > 0, held == 0, !suspended else { return }
        setHidden(true)
    }

    private func setHidden(_ now: Bool) {
        guard hidden != now else { return }
        hidden = now
        BCDTouchFeel.controlsHidden = now
    }
}

extension BCDTouchFeelModel {
    /// The touches of an event that are still down: the finger count `controlsTouched` wants.
    static func fingersDown(in event: UIEvent) -> Int {
        (event.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }.count
    }
}
