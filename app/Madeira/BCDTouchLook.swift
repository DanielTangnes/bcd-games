// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// How the touch controls look (round 604): the colour of their bodies, an accent colour for what is pressed, the symbols on the
// face buttons, and how a press shows. A taste of the person holding the device, not of a game: one choice for every game,
// kept in the app's own preferences (BCDInputPrefs, the feature "touchlook").
//
// Every choice starts at what BCD always drew (the night-violet body, the violet-to-fuchsia light on a press, the Xbox letters
// with their colours); `BCDTouchLook()` is that look, and the views draw it with the code they always had. Plain values,
// Foundation only: BCDTouchLookViews.swift turns a look into colours and the face's picture.

struct BCDTouchRGB: Equatable {
    var r: Double, g: Double, b: Double
}

struct BCDTouchLook: Equatable {
    /// The colour of a control's body and its label.
    enum Body: String, CaseIterable {
        case night = "", graphite, light, clear
        var title: String {
            switch self {
            case .night: return "Night"
            case .graphite: return "Graphite"
            case .light: return "Light"
            case .clear: return "Outline only"
            }
        }
    }

    /// The colour a pressed control lights up in.
    enum Accent: String, CaseIterable {
        case violet = "", blue, green, red, amber, white
        var title: String {
            switch self {
            case .violet: return "BCD violet"
            case .blue: return "Blue"
            case .green: return "Green"
            case .red: return "Red"
            case .amber: return "Amber"
            case .white: return "White"
            }
        }
        /// The two ends of the light on a pressed control; nil for BCD's own (the views use BCDStyle's violet and fuchsia).
        var ends: (BCDTouchRGB, BCDTouchRGB)? {
            switch self {
            case .violet: return nil
            case .blue: return (BCDTouchRGB(r: 0.145, g: 0.388, b: 0.922), BCDTouchRGB(r: 0.376, g: 0.647, b: 0.980))
            case .green: return (BCDTouchRGB(r: 0.063, g: 0.725, b: 0.506), BCDTouchRGB(r: 0.204, g: 0.827, b: 0.600))
            case .red: return (BCDTouchRGB(r: 0.863, g: 0.149, b: 0.149), BCDTouchRGB(r: 0.984, g: 0.443, b: 0.522))
            case .amber: return (BCDTouchRGB(r: 0.851, g: 0.467, b: 0.024), BCDTouchRGB(r: 0.984, g: 0.749, b: 0.141))
            case .white: return (BCDTouchRGB(r: 0.820, g: 0.835, b: 0.859), BCDTouchRGB(r: 1, g: 1, b: 1))
            }
        }
    }

    /// The symbols on the face buttons and the shoulders.
    enum Icons: String, CaseIterable {
        case xbox = "", playstation
        var title: String { self == .xbox ? "Xbox letters" : "PlayStation symbols" }
    }

    /// How a press shows.
    enum Press: String, CaseIterable {
        case glow = "", solid, ring, soft
        var title: String {
            switch self {
            case .glow: return "BCD light"
            case .solid: return "Solid colour"
            case .ring: return "Bright ring"
            case .soft: return "Soft"
            }
        }
    }

    var body = Body.night
    var accent = Accent.violet
    var icons = Icons.xbox
    var press = Press.glow

    var isStandard: Bool { self == BCDTouchLook() }

    /// The lines this feature keeps (the feature "touchlook", the same for every game).
    static let lineNames = ["look-body", "look-accent", "look-icons", "look-press"]

    static func parse(_ get: (String) -> String?) -> BCDTouchLook {
        func word(_ line: String) -> String { (get(line) ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        var look = BCDTouchLook()
        look.body = Body(rawValue: word("look-body")) ?? .night
        look.accent = Accent(rawValue: word("look-accent")) ?? .violet
        look.icons = Icons(rawValue: word("look-icons")) ?? .xbox
        look.press = Press(rawValue: word("look-press")) ?? .glow
        return look
    }

    // MARK: Body colours

    /// A body's fill, rim and label (the label is also what shows over the fill); nil for Night, which is BCD's own.
    var bodyColors: (fill: BCDTouchRGB, rim: BCDTouchRGB, label: BCDTouchRGB)? {
        switch body {
        case .night: return nil
        case .graphite: return (BCDTouchRGB(r: 0.141, g: 0.145, b: 0.165), BCDTouchRGB(r: 0.78, g: 0.80, b: 0.84), BCDTouchRGB(r: 0.96, g: 0.96, b: 0.98))
        case .light: return (BCDTouchRGB(r: 0.95, g: 0.95, b: 0.97), BCDTouchRGB(r: 0.35, g: 0.37, b: 0.42), BCDTouchRGB(r: 0.10, g: 0.10, b: 0.14))
        case .clear: return (BCDTouchRGB(r: 1, g: 1, b: 1), BCDTouchRGB(r: 1, g: 1, b: 1), BCDTouchRGB(r: 1, g: 1, b: 1))
        }
    }

    /// How much of the fill shows when idle (the views multiply it by the layout's opacity). Night is 0.46 as it always was.
    var fillStrength: Double {
        switch body {
        case .night: return 0.46
        case .graphite: return 0.62
        case .light: return 0.78
        case .clear: return 0.04
        }
    }

    /// The same for a stick's ring, a little clearer than a button's (0.36 for Night, as it always was).
    var stickFillStrength: Double {
        switch body {
        case .night: return 0.36
        case .graphite: return 0.48
        case .light: return 0.62
        case .clear: return 0.03
        }
    }

    // MARK: Faces

    enum Glyph: Equatable {
        case text(String)
        case symbol(String)
    }

    /// What a controller input's face shows instead of its letters; nil keeps what BCD always drew.
    func glyph(pad name: String) -> Glyph? {
        guard icons == .playstation else { return nil }
        switch name {
        case "A": return .symbol("xmark")
        case "B": return .symbol("circle")
        case "X": return .symbol("square")
        case "Y": return .symbol("triangle")
        case "LB": return .text("L1")
        case "RB": return .text("R1")
        case "LT": return .text("L2")
        case "RT": return .text("R2")
        default: return nil
        }
    }

    /// The colour of a face button's rim and symbol under PlayStation symbols; nil keeps BCD's Xbox colours.
    func faceTint(pad name: String) -> BCDTouchRGB? {
        guard icons == .playstation else { return nil }
        switch name {
        case "A": return BCDTouchRGB(r: 0.482, g: 0.608, b: 0.859)   // cross, blue
        case "B": return BCDTouchRGB(r: 0.918, g: 0.396, b: 0.431)   // circle, red
        case "X": return BCDTouchRGB(r: 0.867, g: 0.553, b: 0.757)   // square, pink
        case "Y": return BCDTouchRGB(r: 0.384, g: 0.769, b: 0.576)   // triangle, green
        default: return nil
        }
    }

    // MARK: Words

    var summary: String {
        isStandard ? "BCD's own" : [body.title, accent.title, icons.title].joined(separator: " · ")
    }
}
