// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// The touch controls' look on the screen (round 604; BCDTouchLook.swift has the choices): the colours and fills a face draws
// with for a look, the model the live controls watch, and a strip of sample buttons the menu and the game page show.
//
// BCD's own look draws with the very values (BCDTouchPalette's, BCDStyle's) and the same fills and strokes the controls always
// had; another look changes colours and which fill a press uses, never the cost of a frame: nothing animates, nothing blurs, and
// nothing is drawn until a finger moves.

private struct BCDTouchLookKey: EnvironmentKey { static let defaultValue = BCDTouchLook() }

extension EnvironmentValues {
    var bcdTouchLook: BCDTouchLook {
        get { self[BCDTouchLookKey.self] }
        set { self[BCDTouchLookKey.self] = newValue }
    }
}

extension BCDTouchRGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// What a face draws with, for a look.
struct BCDTouchPaint {
    let look: BCDTouchLook

    var fill: Color { look.bodyColors?.fill.color ?? BCDTouchPalette.fill }
    var rim: Color { look.bodyColors?.rim.color ?? BCDTouchPalette.rim }
    var label: Color { look.bodyColors?.label.color ?? BCDTouchPalette.label }
    var fillStrength: Double { look.fillStrength }
    var stickFillStrength: Double { look.stickFillStrength }

    private var low: Color { look.accent.ends?.0.color ?? BCDStyle.violet }
    private var high: Color { look.accent.ends?.1.color ?? BCDStyle.fuchsia }
    /// The face buttons' colours go on a label only where it stays readable (not on the Light body's pale fill; the rim keeps them).
    var tintsLabels: Bool { look.body != .light }
    /// A white light needs a dark label.
    private var onLight: Bool { look.accent == .white }

    /// The colour of a face button's rim and symbol: the PlayStation symbols' own, else the Xbox colours.
    func tint(pad name: String?) -> Color? {
        if let name, let color = look.faceTint(pad: name) { return color.color }
        return BCDTouchPalette.face(name)
    }

    /// A pressed control's fill.
    func pressedFill(_ opacity: Double) -> AnyShapeStyle {
        switch look.press {
        case .glow:
            if look.accent == .violet { return AnyShapeStyle(BCDTouchPalette.pressed(opacity)) }
            return AnyShapeStyle(LinearGradient(colors: [low.opacity(0.92 * opacity), high.opacity(0.92 * opacity)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .solid: return AnyShapeStyle(high.opacity(0.9 * opacity))
        case .ring: return AnyShapeStyle(fill.opacity(fillStrength * opacity))
        case .soft: return AnyShapeStyle(rim.opacity(0.3 * opacity))
        }
    }

    /// A stick's knob while it is held.
    func knobPressedFill(_ opacity: Double) -> AnyShapeStyle {
        switch look.press {
        case .glow, .solid: return pressedFill(opacity)
        case .ring: return AnyShapeStyle(high.opacity(0.9 * opacity))
        case .soft: return AnyShapeStyle(rim.opacity(0.7 * opacity))
        }
    }

    var pressedRim: Color {
        switch look.press {
        case .glow, .solid: return onLight ? Color(red: 0.1, green: 0.1, blue: 0.14) : Color.white
        case .ring: return high
        case .soft: return label
        }
    }

    var pressedLabel: Color {
        switch look.press {
        case .glow, .solid: return onLight ? Color(red: 0.1, green: 0.1, blue: 0.14) : Color.white
        case .ring: return high
        case .soft: return label
        }
    }

    /// A press under Bright ring draws the rim twice as thick.
    var pressedRimFactor: CGFloat { look.press == .ring ? 2 : 1 }
}

/// The look the live controls watch. One for the app; it reads the preferences when it is made and when a choice changes.
@MainActor final class BCDTouchLookModel: ObservableObject {
    static let shared = BCDTouchLookModel()
    static let feature = "touchlook"

    @Published private(set) var look: BCDTouchLook

    init() { look = Self.stored() }

    static func stored() -> BCDTouchLook {
        let lines = BCDInputPrefs.shared.lines(feature, game: BCDInputPrefs.everyone)
        return BCDTouchLook.parse { lines[$0] }
    }

    func reload() {
        let now = Self.stored()
        if now != look { look = now }
    }
}

/// Sample buttons in a look, over a game-like picture: what the menu and the game page show beside the choices. A resting row and
/// the same buttons pressed.
struct BCDTouchLookSample: View {
    let look: BCDTouchLook

    var body: some View {
        VStack(spacing: 10) {
            row(down: false)
            row(down: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.22), Color(red: 0.46, green: 0.36, blue: 0.22), Color(red: 0.10, green: 0.12, blue: 0.20)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.bcdTouchLook, look)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A sample of the touch controls in this look")
    }

    private func row(down: Bool) -> some View {
        HStack(spacing: 10) {
            BCDTouchFace(action: .pad("D↑"), diameter: 40, down: down)
            BCDTouchFace(action: .pad("A"), diameter: 40, down: down)
            BCDTouchFace(action: .pad("B"), diameter: 40, down: down)
            BCDTouchFace(action: .pad("X"), diameter: 40, down: down)
            BCDTouchFace(action: .pad("Y"), diameter: 40, down: down)
            BCDTouchFace(action: .pad("LB"), diameter: 40, down: down)
            BCDTouchFace(action: .pad("RT"), diameter: 40, down: down)
            BCDTouchFace(action: .key(0x20), diameter: 40, down: down)
        }
    }
}

/// The sample in the in-game menu: it follows the look as it is chosen.
struct BCDTouchLookSampleLive: View {
    @ObservedObject private var model = BCDTouchLookModel.shared
    var body: some View { BCDTouchLookSample(look: model.look) }
}
