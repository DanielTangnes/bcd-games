// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import CoreGraphics
import Foundation

// The magnifier (round 604, B4): the game's picture enlarged 1.5x, 2x or 3x around a point the player moves, to read small text in an
// installer or a launcher. Nothing is drawn twice: the presented layer is simply given a larger frame, the screen cuts it, and the touch
// mapping reads the same larger rectangle, so a tap still lands on what is under the finger. At 1x, the default, every number below
// returns its input untouched and the game is laid out exactly as it always was.
//
// Plain geometry (tests/host/check-bcd-magnifier.py compiles this file alone). BCDMagnifierLive.swift holds the state, the bar the player
// moves the view with, and the two calls in MetalBackedView.

struct BCDMagnifierState: Equatable {
    static let zooms: [Double] = [1, 1.5, 2, 3]
    /// The share of the visible part that one press of a pan arrow moves the view by.
    static let panStep = 0.5

    /// 1 is off.
    var zoom = 1.0
    /// The point of the picture that sits at the middle of the picture's own place, as shares of the picture (0...1).
    var u = 0.5
    var v = 0.5

    var isOn: Bool { zoom > 1.0001 }

    /// The share of the picture that is on screen along each axis.
    var visible: Double { 1 / max(1, zoom) }

    /// Keeps the middle where the enlarged picture still covers its own place: the picture's edge never moves in from the place's edge.
    func clamped() -> BCDMagnifierState {
        var s = self
        s.zoom = min(max(zoom.isFinite ? zoom : 1, 1), Self.zooms.last!)
        let half = 0.5 / s.zoom
        s.u = min(max(u.isFinite ? u : 0.5, half), 1 - half)
        s.v = min(max(v.isFinite ? v : 0.5, half), 1 - half)
        return s
    }

    /// Another zoom, the middle kept (and kept inside what the new zoom allows).
    func zoomed(to value: Double) -> BCDMagnifierState {
        var s = self
        s.zoom = value
        return s.clamped()
    }

    /// The view moved by `dx` and `dy` of the visible part (-1 is one whole visible width to the left, +1 to the right; -1 up, +1 down).
    func panned(dx: Double, dy: Double) -> BCDMagnifierState {
        var s = self
        s.u += dx * visible
        s.v += dy * visible
        return s.clamped()
    }

    /// The nearest zoom the menu offers (a stored or typed value that is not one of them).
    static func nearestZoom(_ value: Double) -> Double {
        zooms.min { abs($0 - value) < abs($1 - value) }!
    }

    // MARK: Where the picture is

    /// The rectangle the enlarged picture occupies, given where it stands at 1x (`base`). At 1x it is `base` itself, bit for bit.
    /// The point (u, v) of the picture is placed at the middle of `base`, and the picture is `zoom` times as large: with (u, v) at its limits
    /// the enlarged picture's edge is on the place's edge.
    func rect(base: CGRect) -> CGRect {
        guard isOn else { return base }
        let s = clamped()
        let w = base.width * s.zoom, h = base.height * s.zoom
        return CGRect(x: base.midX - s.u * w, y: base.midY - s.v * h, width: w, height: h)
    }

    /// A point on the screen (where a finger is) as it would be with no enlargement: the point of `base` that the finger is over. The game's
    /// own mapping (GameSurfaceLayout.map) then gives the right pixel. At 1x it returns the point unchanged.
    func unzoom(point: CGPoint, base: CGRect) -> CGPoint {
        guard isOn else { return point }
        let big = rect(base: base)
        guard big.width > 0, big.height > 0 else { return point }
        return CGPoint(x: base.minX + (point.x - big.minX) / big.width * base.width,
                       y: base.minY + (point.y - big.minY) / big.height * base.height)
    }

    /// The words under the magnifier row.
    var words: String {
        guard isOn else { return "Off" }
        return String(format: "%g×", zoom)
    }
}

/// The state the picture's layout reads. Main thread: MetalBackedView.gameRect and mapPoint read it, BCDMagnifierLive writes it.
enum BCDMagnifierCurrent {
    nonisolated(unsafe) static var state = BCDMagnifierState()
}
