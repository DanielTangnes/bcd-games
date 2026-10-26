// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI
import UIKit

// The radial menu on the screen (round 604; BCDRadial.swift has the rules): a small button at the edge, and, while a finger is on it or
// it has been tapped, a ring of up to eight slots round it. Drawn from plain values with no engine type; the window that holds it and
// the actions it runs are BCDRadialLive.swift's. Nothing animates and nothing blurs: the ring is a few filled circles drawn when it
// opens and again when the finger moves to another slot.

@MainActor final class BCDRadialModel: ObservableObject {
    @Published var settings = BCDRadialSettings()
    /// What the views read: the ring is open, and which slot a finger is over. They change only when they change.
    @Published private(set) var isOpen = false
    @Published private(set) var highlighted: Int?
    private var touch = BCDRadialTouch()
    /// What choosing a slot does (BCDRadialLive.swift runs it).
    var choose: (BCDInputAction) -> Void = { _ in }
    /// The ring's open state changed (the window takes the whole screen while it is open).
    var openChanged: (Bool) -> Void = { _ in }

    var filledPositions: Set<Int> { Set(settings.filled.map(\.position)) }

    private func publish() {
        if isOpen != touch.isOpen { isOpen = touch.isOpen; openChanged(isOpen) }
        if highlighted != touch.highlighted { highlighted = touch.highlighted }
    }

    func began(at point: CGPoint, onHandle: Bool, position: Int?) {
        let outcome = touch.began(at: point, onHandle: onHandle, position: position, filled: filledPositions)
        if outcome == .open { BCDTouchHaptic.tap() }
        publish()
    }

    func moved(to point: CGPoint, position: Int?) {
        let before = touch.highlighted
        touch.moved(to: point, position: position, filled: filledPositions)
        if touch.highlighted != before, touch.highlighted != nil { BCDTouchHaptic.tap() }
        publish()
    }

    func ended() {
        let outcome = touch.ended(filled: filledPositions)
        if case .choose(let position) = outcome, let action = settings.slots[position] {
            BCDTouchHaptic.tap()
            choose(action)
        }
        publish()
    }

    func cancel() {
        touch.cancelled()
        publish()
    }

    /// A sample for the preview app: the ring open, one slot under the finger.
    func preview(open: Bool, highlighted: Int?) {
        touch = BCDRadialTouch.sample(open: open, highlighted: highlighted)
        isOpen = touch.isOpen
        self.highlighted = touch.highlighted
    }
}

/// The button and the ring over the whole window. `report` tells the window where it takes touches: the button while closed, the whole
/// screen while the ring is open.
struct BCDRadialLayer: View {
    @ObservedObject var model: BCDRadialModel
    let report: (CGRect) -> Void
    @State private var active = false

    var body: some View {
        GeometryReader { geo in
            let insets = BCDSessionInsets.of(geo)
            let ins = (left: insets.leading, right: insets.trailing, top: insets.top, bottom: insets.bottom)
            let handle = BCDRadialGeometry.handleCenter(model.settings.place, screen: geo.size, insets: ins)
            let radius = BCDRadialGeometry.radius(screen: geo.size)
            let ring = BCDRadialGeometry.ringCenter(handle: handle, screen: geo.size, radius: radius, insets: ins)
            let open = model.isOpen
            let handleFrame = CGRect(x: handle.x - BCDRadialGeometry.handle / 2, y: handle.y - BCDRadialGeometry.handle / 2,
                                     width: BCDRadialGeometry.handle, height: BCDRadialGeometry.handle)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let position = BCDRadialGeometry.position(of: value.location, ring: ring, radius: radius)
                            if !active {
                                active = true
                                let onHandle = handleFrame.insetBy(dx: -8, dy: -8).contains(value.startLocation)
                                model.began(at: value.startLocation, onHandle: onHandle, position: position)
                            }
                            model.moved(to: value.location, position: position)
                        }
                        .onEnded { _ in
                            active = false
                            model.ended()
                        })
                if open {
                    ringView(center: ring, radius: radius)
                } else {
                    handleView
                        .position(handle)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .transaction { $0.animation = nil }
            .onAppear { report(open ? CGRect(origin: .zero, size: geo.size) : handleFrame.insetBy(dx: -8, dy: -8)) }
            .onChange(of: open) { _, now in report(now ? CGRect(origin: .zero, size: geo.size) : handleFrame.insetBy(dx: -8, dy: -8)) }
            .onChange(of: geo.size) { _, size in report(open ? CGRect(origin: .zero, size: size) : handleFrame.insetBy(dx: -8, dy: -8)) }
            .onDisappear { report(.zero) }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var handleView: some View {
        let open = model.isOpen
        return Image(systemName: "circle.grid.cross.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(open ? Color.white : BCDStyle.text.opacity(0.9))
            .frame(width: BCDRadialGeometry.handle, height: BCDRadialGeometry.handle)
            .background(Circle().fill(open ? AnyShapeStyle(BCDStyle.glow) : AnyShapeStyle(BCDSessionStyle.panel.opacity(0.6))))
            .overlay(Circle().strokeBorder(open ? BCDStyle.fuchsia : BCDStyle.lavender.opacity(0.45), lineWidth: 1))
            .opacity(open ? 1 : 0.62)
            .accessibilityLabel("Radial menu")
    }

    private func ringView(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.32))
                .frame(width: (radius + BCDRadialGeometry.slot) * 2, height: (radius + BCDRadialGeometry.slot) * 2)
                .position(center)
            // The middle is where a finger chooses nothing.
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(BCDStyle.lavender.opacity(0.55))
                .position(center)
            ForEach(0..<BCDRadialSettings.slotCount, id: \.self) { position in
                slotView(position, center: center, radius: radius)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func slotView(_ position: Int, center: CGPoint, radius: CGFloat) -> some View {
        let at = BCDRadialGeometry.slotCenter(position: position, ring: center, radius: radius)
        if let action = model.settings.slots[position] {
            let lit = model.highlighted == position
            Text(action.cap)
                .font(.system(size: action.cap.count > 4 ? 12 : 15, weight: .heavy, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(lit ? Color.white : BCDStyle.text)
                .frame(width: BCDRadialGeometry.slot, height: BCDRadialGeometry.slot)
                .background(Circle().fill(lit ? AnyShapeStyle(BCDStyle.glow) : AnyShapeStyle(BCDSessionStyle.panel.opacity(0.95))))
                .overlay(Circle().strokeBorder(lit ? Color.white.opacity(0.9) : BCDStyle.lavender.opacity(0.5), lineWidth: lit ? 2 : 1))
                .scaleEffect(lit ? 1.12 : 1)
                .position(at)
                .accessibilityLabel(action.title)
        } else {
            Circle().strokeBorder(BCDStyle.lavender.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: BCDRadialGeometry.slot * 0.7, height: BCDRadialGeometry.slot * 0.7)
                .position(at)
        }
    }
}
