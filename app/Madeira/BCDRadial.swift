// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import CoreGraphics
import Foundation

// The radial menu (round 604): a small button at the edge of the screen; put a finger on it and a ring of up to eight things opens
// round it (a key, Alt+Tab, a click, BCD's menu, a button of the controller...); slide to one and let go, or lift at once and tap
// one. A game with far more keys than a touch layout has room for gets them within a thumb's reach, drawn only while the ring is open.
//
// Per game, off until its player turns it on (the game page's Radial menu, the in-game menu's Controls). This file is plain values
// and arithmetic, Foundation and CoreGraphics only: the settings a game's lines make, where the ring and its slots go, which slot a
// finger is over and what a touch does. BCDRadialViews.swift draws it, BCDRadialLive.swift holds its window and runs the actions.

struct BCDRadialSettings: Equatable {
    var isOn = false
    /// The eight slots clockwise from the top; nil is a slot left empty.
    var slots: [BCDInputAction?] = BCDRadialSettings.defaultSlots
    var place = Place.rightLow

    /// Where the button waits.
    enum Place: String, CaseIterable {
        case rightLow = "", rightMiddle = "right", rightHigh = "right-top", leftLow = "left-bottom", leftMiddle = "left", leftHigh = "left-top"
        var title: String {
            switch self {
            case .rightLow: return "Right, low"
            case .rightMiddle: return "Right, middle"
            case .rightHigh: return "Right, high"
            case .leftLow: return "Left, low"
            case .leftMiddle: return "Left, middle"
            case .leftHigh: return "Left, high"
            }
        }
        var onRight: Bool { self == .rightLow || self == .rightMiddle || self == .rightHigh }
        /// 0 at the top of the screen, 1 at the bottom.
        var height: Double {
            switch self {
            case .rightHigh, .leftHigh: return 0.22
            case .rightMiddle, .leftMiddle: return 0.5
            case .rightLow, .leftLow: return 0.78
            }
        }
    }

    static let slotCount = 8
    /// What a game that turned the ring on and chose nothing gets: the keys most games ask for, clockwise from the top.
    static let defaultSlotIDs = ["esc", "tab", "enter", "space", "i", "m", "f5", "f9"]
    static let defaultSlots: [BCDInputAction?] = defaultSlotIDs.map { BCDInputAction.parse($0) }
    /// The lines of a game this feature keeps: `radial` ("1" is on), `radial-place`, `radial-1` to `radial-8` (an action's name, or
    /// "none" for an empty slot; no line is the default slot).
    static let lineNames = ["radial", "radial-place"] + (1...slotCount).map { "radial-\($0)" }

    static func parse(_ get: (String) -> String?) -> BCDRadialSettings {
        var s = BCDRadialSettings()
        s.isOn = (get("radial") ?? "").trimmingCharacters(in: .whitespaces) == "1"
        s.place = Place(rawValue: (get("radial-place") ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? .rightLow
        for n in 1...slotCount {
            guard let text = get("radial-\(n)")?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { continue }
            s.slots[n - 1] = text == "none" ? nil : (BCDInputAction.parse(text) ?? defaultSlots[n - 1])
        }
        return s
    }

    /// The slots that hold something, in ring order, with their position on the ring (empty slots keep their places).
    var filled: [(position: Int, action: BCDInputAction)] {
        slots.enumerated().compactMap { i, a in a.map { (i, $0) } }
    }
}

/// Where the ring and its slots go, and which slot a finger is over.
enum BCDRadialGeometry {
    /// The button's diameter and a slot's, in points.
    static let handle: CGFloat = 54, slot: CGFloat = 56
    /// A finger this close to the ring's centre, or further than `reach` times the radius from it, is over no slot.
    static let dead: CGFloat = 0.38, reach: CGFloat = 2.2
    /// A press that has moved less than this when the finger lifts opens the ring and leaves it open for a tap.
    static let tapTravel: CGFloat = 18

    /// The ring's radius: roomy for an iPad.
    static func radius(screen: CGSize) -> CGFloat { min(screen.width, screen.height) >= 700 ? 118 : 94 }

    /// The button's centre: against the left or right edge inside the safe area, at the place's height.
    static func handleCenter(_ place: BCDRadialSettings.Place, screen: CGSize, insets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)) -> CGPoint {
        let edge: CGFloat = 12 + handle / 2
        let x = place.onRight ? screen.width - max(insets.right, 8) - edge : max(insets.left, 8) + edge
        let top = max(insets.top, 8) + handle / 2, bottom = screen.height - max(insets.bottom, 8) - handle / 2
        let y = top + (bottom - top) * CGFloat(place.height)
        return CGPoint(x: x, y: y)
    }

    /// The ring's centre: the button's, moved in so every slot stays on the screen inside the safe area.
    static func ringCenter(handle center: CGPoint, screen: CGSize, radius: CGFloat,
                           insets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)) -> CGPoint {
        let pad = radius + slot / 2 + 4
        let minX = max(insets.left, 0) + pad, maxX = screen.width - max(insets.right, 0) - pad
        let minY = max(insets.top, 0) + pad, maxY = screen.height - max(insets.bottom, 0) - pad
        return CGPoint(x: minX <= maxX ? min(max(center.x, minX), maxX) : screen.width / 2,
                       y: minY <= maxY ? min(max(center.y, minY), maxY) : screen.height / 2)
    }

    /// A slot's centre: `position` 0 is straight up, and they go clockwise in eighths.
    static func slotCenter(position: Int, ring: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = Double(position) * .pi / 4
        return CGPoint(x: ring.x + radius * CGFloat(sin(angle)), y: ring.y - radius * CGFloat(cos(angle)))
    }

    /// The slot position (0...7) the point is over, nil near the centre or too far out. Eight sectors of 45°, the first centred on up.
    static func position(of point: CGPoint, ring: CGPoint, radius: CGFloat) -> Int? {
        let dx = Double(point.x - ring.x), dy = Double(point.y - ring.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= Double(radius * dead), distance <= Double(radius * reach) else { return nil }
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return Int((degrees + 22.5) / 45) % 8
    }
}

/// What a touch on the radial menu does, one finger from touch-down to lift.
struct BCDRadialTouch {
    enum Outcome: Equatable {
        /// Nothing yet, or the ring stays as it is.
        case none
        /// The ring opens.
        case open
        /// The ring closes with nothing chosen.
        case close
        /// The ring closes and this slot's action runs.
        case choose(Int)
    }

    private(set) var isOpen = false
    /// The ring was left open by a short press: the next touch chooses.
    private(set) var sticky = false
    private(set) var highlighted: Int?
    private var start = CGPoint.zero
    private var travelled: CGFloat = 0
    private var began = false

    /// The finger went down at `point`. `onHandle`: it is on the button; `position`: the slot it is over when the ring is open.
    mutating func began(at point: CGPoint, onHandle: Bool, position: Int?, filled: Set<Int>) -> Outcome {
        start = point
        travelled = 0
        began = true
        if isOpen {
            highlighted = position.flatMap { filled.contains($0) ? $0 : nil }
            return .none
        }
        guard onHandle else { began = false; return .none }
        isOpen = true
        sticky = false
        highlighted = nil
        return .open
    }

    /// The finger moved to `point`, over `position`.
    mutating func moved(to point: CGPoint, position: Int?, filled: Set<Int>) {
        guard began else { return }
        travelled = max(travelled, hypot(point.x - start.x, point.y - start.y))
        // A finger that has hardly moved from the button is not choosing yet, whatever slot happens to lie under it.
        guard sticky || travelled >= BCDRadialGeometry.tapTravel else { highlighted = nil; return }
        highlighted = position.flatMap { filled.contains($0) ? $0 : nil }
    }

    /// The finger lifted.
    mutating func ended(filled: Set<Int>) -> Outcome {
        guard began else { return .none }
        began = false
        defer { highlighted = nil }
        if sticky {
            // A tap while the ring waits: a slot chooses it, anywhere else closes the ring.
            isOpen = false
            sticky = false
            if let h = highlighted, filled.contains(h) { return .choose(h) }
            return .close
        }
        if travelled < BCDRadialGeometry.tapTravel {
            // A short press on the button: the ring stays open for a tap.
            sticky = true
            return .none
        }
        isOpen = false
        if let h = highlighted, filled.contains(h) { return .choose(h) }
        return .close
    }

    /// The touch was taken away (the app left the foreground, a menu opened): everything closes, nothing runs.
    mutating func cancelled() {
        isOpen = false
        sticky = false
        highlighted = nil
        began = false
    }
}

extension BCDRadialTouch {
    /// A touch in a given state, for the preview app's pictures.
    static func sample(open: Bool, highlighted: Int?) -> BCDRadialTouch {
        var t = BCDRadialTouch()
        guard open else { return t }
        _ = t.began(at: .zero, onHandle: true, position: nil, filled: [])
        t.moved(to: CGPoint(x: 100, y: 0), position: highlighted, filled: Set(0..<8))
        return t
    }
}
