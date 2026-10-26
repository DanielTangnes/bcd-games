// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The Apple Pencil as a precise mouse (round 604). A finger on a game is a touch, a trackpad or a camera, whichever the pointer
// setting says; the Pencil can be what a mouse is: its tip puts the pointer exactly where it touches, the nib on the glass is the left
// button, hovering over the glass (an iPad Pro or Air with hover) moves the pointer without a click, and a squeeze or a double tap of
// the Pencil is a right click. Per game, off until its player turns it on. Plain values and rules, Foundation only: the settings, and the
// pointer events a Pencil's touches make. BCDPencilLive.swift reads the Pencil and posts them.

struct BCDPencilSettings: Equatable {
    var isOn = false
    /// What a squeeze or a double tap of the Pencil does.
    var tap = Tap.right

    enum Tap: String, CaseIterable {
        case right = "", middle, none
        var title: String {
            switch self {
            case .right: return "A right click"
            case .middle: return "A middle click"
            case .none: return "Nothing"
            }
        }
    }

    /// The lines of a game this feature keeps: `pencil` ("1" is on) and `pencil-tap`.
    static let lineNames = ["pencil", "pencil-tap"]

    static func parse(_ get: (String) -> String?) -> BCDPencilSettings {
        var s = BCDPencilSettings()
        s.isOn = (get("pencil") ?? "").trimmingCharacters(in: .whitespaces) == "1"
        s.tap = Tap(rawValue: (get("pencil-tap") ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .right
        return s
    }
}

/// The pointer events a Pencil's touches and hovers make, in guest pixels.
struct BCDPencilPointer {
    enum Op: Equatable {
        /// The pointer goes to the point (no button).
        case move(Int32, Int32)
        case leftDown(Int32, Int32)
        case leftUp(Int32, Int32)
        case click(Button, Int32, Int32)
    }
    enum Button: Equatable { case right, middle }

    private(set) var down = false
    private(set) var last: (x: Int32, y: Int32)?
    private var lastMoved: (x: Int32, y: Int32)?

    /// The nib touched the glass.
    mutating func touchBegan(x: Int32, y: Int32) -> [Op] {
        last = (x, y)
        lastMoved = (x, y)
        down = true
        return [.move(x, y), .leftDown(x, y)]
    }

    /// The nib moved on the glass (the same place twice is one move).
    mutating func touchMoved(x: Int32, y: Int32) -> [Op] {
        last = (x, y)
        guard down, lastMoved?.x != x || lastMoved?.y != y else { return [] }
        lastMoved = (x, y)
        return [.move(x, y)]
    }

    /// The nib left the glass.
    mutating func touchEnded(x: Int32, y: Int32) -> [Op] {
        last = (x, y)
        guard down else { return [] }
        down = false
        return [.leftUp(x, y)]
    }

    /// The touch was taken away: the button comes up where the pointer is.
    mutating func touchCancelled() -> [Op] {
        guard down else { return [] }
        down = false
        let p = last ?? (0, 0)
        return [.leftUp(p.x, p.y)]
    }

    /// The nib hovers over the glass: the pointer follows; nothing while it touches.
    mutating func hovered(x: Int32, y: Int32) -> [Op] {
        last = (x, y)
        guard !down, lastMoved?.x != x || lastMoved?.y != y else { return [] }
        lastMoved = (x, y)
        return [.move(x, y)]
    }

    /// A squeeze or a double tap, at `point` when the Pencil says where and else where it was last.
    func tapped(_ tap: BCDPencilSettings.Tap, at point: (x: Int32, y: Int32)?) -> [Op] {
        guard tap != .none, let p = point ?? last else { return [] }
        return [.click(tap == .middle ? .middle : .right, p.x, p.y)]
    }

    /// The feature goes off: a button that is down comes up.
    mutating func reset() -> [Op] { touchCancelled() }
}
