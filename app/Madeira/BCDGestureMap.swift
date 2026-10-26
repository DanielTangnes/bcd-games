// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import CoreGraphics
import Foundation

// Touch gestures for a game (round 604): a tap with two, three or four fingers, a swipe with two or three, a pinch in or out, each
// bound to one thing BCD can do (BCDInputAction.swift: a key, Alt+Tab, a click, the wheel, BCD's menu, the key bar, a button of the
// controller). Per game, nothing bound until its player binds one. This file is plain values and rules, Foundation and CoreGraphics
// only: the bindings a game's lines make, and the tracker that says which gesture a set of fingers made once the last one lifts.
// BCDGestureLive.swift feeds it the touches and runs the action.

enum BCDGesture: String, CaseIterable {
    case tap2, tap3, tap4
    case swipe2Left = "swipe2-left", swipe2Right = "swipe2-right", swipe2Up = "swipe2-up", swipe2Down = "swipe2-down"
    case swipe3Left = "swipe3-left", swipe3Right = "swipe3-right", swipe3Up = "swipe3-up", swipe3Down = "swipe3-down"
    case pinchIn = "pinch-in", pinchOut = "pinch-out"

    var title: String {
        switch self {
        case .tap2: return "Tap with two fingers"
        case .tap3: return "Tap with three fingers"
        case .tap4: return "Tap with four fingers"
        case .swipe2Left: return "Swipe left with two fingers"
        case .swipe2Right: return "Swipe right with two fingers"
        case .swipe2Up: return "Swipe up with two fingers"
        case .swipe2Down: return "Swipe down with two fingers"
        case .swipe3Left: return "Swipe left with three fingers"
        case .swipe3Right: return "Swipe right with three fingers"
        case .swipe3Up: return "Swipe up with three fingers"
        case .swipe3Down: return "Swipe down with three fingers"
        case .pinchIn: return "Pinch in with two fingers"
        case .pinchOut: return "Spread two fingers"
        }
    }

    var line: String { "gesture-" + rawValue }
}

struct BCDGestureSettings: Equatable {
    var bindings: [BCDGesture: BCDInputAction] = [:]

    var isOn: Bool { !bindings.isEmpty }

    static let lineNames = BCDGesture.allCases.map(\.line)

    static func parse(_ get: (String) -> String?) -> BCDGestureSettings {
        var s = BCDGestureSettings()
        for gesture in BCDGesture.allCases {
            if let text = get(gesture.line), let action = BCDInputAction.parse(text) { s.bindings[gesture] = action }
        }
        return s
    }
}

/// Which gesture the fingers made, decided when the last one lifts.
struct BCDGestureTracker {
    private struct Finger {
        var start: CGPoint
        var now: CGPoint
        var downTime: Double
    }

    private var fingers: [Int: Finger] = [:]
    /// The fingers of this gesture that have lifted, where they ended.
    private var lifted: [Int: Finger] = [:]
    private var peak = 0
    private var firstDown = 0.0
    private var lastDown = 0.0
    private var spoiled = false

    // The thresholds, in points and seconds.
    static let landTogether = 0.30        // every finger of a gesture lands within this of the first
    static let tapDuration = 0.45, tapTravel = 14.0
    static let swipeTravel = 70.0, swipeDuration = 1.0, swipeSkew = 1.5
    static let pinchRatio = 1.35

    var isTracking: Bool { !fingers.isEmpty }

    mutating func down(id: Int, at point: CGPoint, time: Double) {
        if fingers.isEmpty {
            peak = 0
            firstDown = time
            spoiled = false
        }
        // A finger that lands long after the first is not part of one gesture.
        if !fingers.isEmpty && time - firstDown > Self.landTogether { spoiled = true }
        fingers[id] = Finger(start: point, now: point, downTime: time)
        lastDown = time
        peak = max(peak, fingers.count)
    }

    mutating func move(id: Int, to point: CGPoint) {
        fingers[id]?.now = point
    }

    /// A finger lifted. When it was the last one, the gesture the fingers made, if any.
    mutating func up(id: Int, at point: CGPoint, time: Double) -> BCDGesture? {
        guard var finger = fingers[id] else { return nil }
        finger.now = point
        lifted[id] = finger
        fingers[id] = nil
        guard fingers.isEmpty else { return nil }
        defer { lifted.removeAll(); peak = 0 }
        return classify(duration: time - firstDown)
    }

    /// The touches were taken away: nothing happened.
    mutating func cancel() {
        fingers.removeAll()
        lifted.removeAll()
        peak = 0
    }

    private func classify(duration: Double) -> BCDGesture? {
        let all = Array(lifted.values)
        guard !spoiled, all.count == peak, (2...4).contains(peak), duration <= Self.swipeDuration else { return nil }
        let moves = all.map { hypot(Double($0.now.x - $0.start.x), Double($0.now.y - $0.start.y)) }
        let startC = centroid(all.map(\.start)), endC = centroid(all.map(\.now))
        let dx = Double(endC.x - startC.x), dy = Double(endC.y - startC.y)
        let shift = hypot(dx, dy)

        if duration <= Self.tapDuration, (moves.max() ?? 0) <= Self.tapTravel {
            return peak == 2 ? .tap2 : peak == 3 ? .tap3 : .tap4
        }
        if peak == 2 {
            let d0 = distance(all[0].start, all[1].start), d1 = distance(all[0].now, all[1].now)
            if d0 > 10 {
                let ratio = d1 / d0
                if ratio >= Self.pinchRatio && shift < Self.swipeTravel { return .pinchOut }
                if ratio <= 1 / Self.pinchRatio && shift < Self.swipeTravel { return .pinchIn }
                if ratio > 1.3 || ratio < 0.75 { return nil }   // a swipe with a changing spread is neither
            }
        }
        guard (2...3).contains(peak), shift >= Self.swipeTravel else { return nil }
        let horizontal = abs(dx) >= abs(dy) * Self.swipeSkew, vertical = abs(dy) >= abs(dx) * Self.swipeSkew
        if horizontal { return peak == 2 ? (dx < 0 ? .swipe2Left : .swipe2Right) : (dx < 0 ? .swipe3Left : .swipe3Right) }
        if vertical { return peak == 2 ? (dy < 0 ? .swipe2Up : .swipe2Down) : (dy < 0 ? .swipe3Up : .swipe3Down) }
        return nil
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(points.count, 1))
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }
}
