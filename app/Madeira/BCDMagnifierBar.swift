// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// The magnifier's bar over the game (round 604, B4): smaller and larger, four arrows that move the enlarged view, and a close. A handle at its
// left moves the bar, which keeps where it was left. It exists only while the magnifier is on; it draws only when the zoom changes or a finger
// moves it. Drawn from plain values: the window and the state are BCDMagnifierLive.swift's.

@MainActor final class BCDMagnifierBarModel: ObservableObject {
    @Published var state = BCDMagnifierState()
}

struct BCDMagnifierBar: View {
    @ObservedObject var model: BCDMagnifierBarModel
    let zoom: (Int) -> Void
    let pan: (Double, Double) -> Void
    let close: () -> Void
    let handle: AnyView

    var body: some View {
        HStack(spacing: 4) {
            handle
            button("minus", "Smaller", enabled: model.state.zoom > BCDMagnifierState.zooms[0] + 0.001) { zoom(-1) }
            Text(verbatim: model.state.words)
                .font(BCDStyle.label(14).monospacedDigit())
                .foregroundStyle(BCDStyle.text)
                .frame(minWidth: 40)
            button("plus", "Larger", enabled: model.state.zoom < BCDMagnifierState.zooms.last! - 0.001) { zoom(1) }
            Rectangle().fill(BCDStyle.stroke).frame(width: 1, height: 24).padding(.horizontal, 2)
            button("chevron.left", "Move the view left", enabled: true) { pan(-1, 0) }
            button("chevron.up", "Move the view up", enabled: true) { pan(0, -1) }
            button("chevron.down", "Move the view down", enabled: true) { pan(0, 1) }
            button("chevron.right", "Move the view right", enabled: true) { pan(1, 0) }
            button("xmark", "Close the magnifier", enabled: true, close)
        }
        .padding(.trailing, 4)
        .frame(height: 48)
        .background(BCDSessionStyle.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(BCDStyle.stroke, lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? BCDStyle.text : BCDStyle.textSoft.opacity(0.45))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The bar's place: a share of the window, kept per device, moved by its handle, inside the safe area. `report` tells the window where the bar
/// is, for the touches it takes; the rest of the window belongs to the game.
struct BCDMagnifierBarLayer: View {
    @ObservedObject var model: BCDMagnifierBarModel
    let zoom: (Int) -> Void
    let pan: (Double, Double) -> Void
    let close: () -> Void
    let report: (CGRect) -> Void

    @AppStorage("bcdMagnifierBarX") private var nx = 0.5
    @AppStorage("bcdMagnifierBarY") private var ny = 0.0
    @GestureState private var drag = CGSize.zero
    @State private var barSize = CGSize(width: 380, height: 48)

    var body: some View {
        GeometryReader { geo in
            let insets = BCDSessionInsets.of(geo)
            let point = center(geo.size, insets, shift: drag)
            let frame = CGRect(x: point.x - barSize.width / 2, y: point.y - barSize.height / 2, width: barSize.width, height: barSize.height)
            BCDMagnifierBar(model: model, zoom: zoom, pan: pan, close: close, handle: AnyView(handleView(geo.size, insets)))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .position(point)
                .onAppear { report(frame) }
                .onChange(of: frame) { _, value in report(value) }
                .onDisappear { report(.zero) }
        }
        .ignoresSafeArea()
    }

    private func center(_ size: CGSize, _ insets: EdgeInsets, shift: CGSize) -> CGPoint {
        let left = insets.leading + barSize.width / 2 + 8
        let right = max(left, size.width - insets.trailing - barSize.width / 2 - 8)
        let top = insets.top + barSize.height / 2 + 8
        let bottom = max(top, size.height - insets.bottom - barSize.height / 2 - 8)
        return CGPoint(x: min(max(left, size.width * nx + shift.width), right),
                       y: min(max(top, size.height * ny + shift.height), bottom))
    }

    private func handleView(_ size: CGSize, _ insets: EdgeInsets) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(BCDStyle.textSoft)
            .frame(width: 40, height: 48)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($drag) { value, state, transaction in
                        transaction.animation = nil
                        state = value.translation
                    }
                    .onEnded { value in
                        let end = center(size, insets, shift: value.translation)
                        nx = end.x / max(1, size.width)
                        ny = end.y / max(1, size.height)
                    })
            .accessibilityLabel("Move the magnifier bar")
    }
}
