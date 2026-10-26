// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// The floating key bar over a running game (round 603): Ctrl, Alt and Shift as latches, then Esc,
// Tab, Enter, Alt+Tab, Alt+Enter, Win, Del, F1 to F12, Space and the navigation keys, in one row
// that scrolls. It is opened from the in-game menu (Game › Key bar) and closed with its own ×;
// a handle at its left moves it, and it keeps where it was left. The keys it sends are
// BCDExtraKeys.swift's; the window that holds it and posts them is BCDExtraKeysLive.swift. Drawn
// from plain values: no engine type here. It exists only while it is open and draws only when a
// latch changes or a finger moves it.

/// Which modifiers the bar holds down, for the keys to glow.
@MainActor final class BCDExtraKeyBarModel: ObservableObject {
    @Published var states: [Int32: BCDModifierLatches.State] = [:]
}

struct BCDExtraKeyBar: View {
    @ObservedObject var model: BCDExtraKeyBarModel
    let press: (BCDExtraKey) -> Void
    let longPress: (BCDExtraKey) -> Void
    let close: () -> Void
    let handle: AnyView

    var body: some View {
        HStack(spacing: 0) {
            handle
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BCDExtraKeys.bar) { key in
                        BCDExtraKeyCap(key: key, state: key.modifierCode.flatMap { model.states[$0] },
                                       press: press, longPress: longPress)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(BCDStyle.textSoft)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the key bar")
        }
        .frame(height: 48)
        .background(BCDSessionStyle.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(BCDStyle.stroke, lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

/// One key of the bar. A modifier glows while it is held for the next key and shows a lock when
/// it is locked (a long press); a tap on a held one lets it go.
struct BCDExtraKeyCap: View {
    let key: BCDExtraKey
    let state: BCDModifierLatches.State?
    let press: (BCDExtraKey) -> Void
    let longPress: (BCDExtraKey) -> Void

    var body: some View {
        let held = state != nil
        let cap = HStack(spacing: 3) {
            Text(key.title)
                .font(BCDStyle.label(14))
                .lineLimit(1)
            if state == .locked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)) }
        }
        .foregroundStyle(held ? Color.white : BCDStyle.text)
        .frame(minWidth: 40, minHeight: 36)
        .padding(.horizontal, 7)
        .background {
            if state == .locked { Capsule().fill(BCDStyle.glow) }
            else if state == .once { Capsule().fill(BCDStyle.violet.opacity(0.55)) }
            else { Capsule().fill(BCDStyle.surfaceRaised) }
        }
        .overlay(Capsule().strokeBorder(held ? BCDStyle.fuchsia : BCDStyle.stroke, lineWidth: held ? 1.5 : 1))
        .contentShape(Capsule())
        if key.isModifier {
            cap
                .onTapGesture { press(key) }
                .onLongPressGesture(minimumDuration: 0.45) { longPress(key) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(key.spoken ?? key.title)
                .accessibilityValue(state == .locked ? "Locked" : state == .once ? "Held for the next key" : "Off")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Lock") { longPress(key) }
        } else {
            cap
                .onTapGesture { press(key) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(key.spoken ?? key.title)
                .accessibilityAddTraits(.isButton)
        }
    }
}

/// The bar's place on the screen: a share of the window, kept per device, and moved by its handle
/// only (a finger on a key scrolls the row). It stays inside the safe area. `report` tells the
/// window where the bar is, for the touches it takes; the rest of the window belongs to the game.
struct BCDExtraKeyBarLayer: View {
    @ObservedObject var model: BCDExtraKeyBarModel
    let press: (BCDExtraKey) -> Void
    let longPress: (BCDExtraKey) -> Void
    let close: () -> Void
    let report: (CGRect) -> Void

    @AppStorage("bcdExtraKeyBarX") private var nx = 0.5
    @AppStorage("bcdExtraKeyBarY") private var ny = 1.0
    @GestureState private var drag = CGSize.zero
    @State private var barSize = CGSize(width: 480, height: 48)

    var body: some View {
        GeometryReader { geo in
            let insets = BCDSessionInsets.of(geo)
            let width = Self.width(for: geo.size.width - insets.leading - insets.trailing)
            let point = center(geo.size, insets, width: width, shift: drag)
            let frame = CGRect(x: point.x - width / 2, y: point.y - barSize.height / 2, width: width, height: barSize.height)
            BCDExtraKeyBar(model: model, press: press, longPress: longPress, close: close, handle: AnyView(handleView(geo.size, insets, width)))
                .frame(width: width)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .position(point)
                .onAppear { report(frame) }
                .onChange(of: frame) { _, value in report(value) }
                .onDisappear { report(.zero) }
        }
        .ignoresSafeArea()
    }

    /// The bar's width: all of the safe width on a narrow screen, 600 at most.
    static func width(for available: CGFloat) -> CGFloat { max(160, min(600, available - 16)) }

    private func center(_ size: CGSize, _ insets: EdgeInsets, width: CGFloat, shift: CGSize) -> CGPoint {
        let left = insets.leading + width / 2 + 8
        let right = max(left, size.width - insets.trailing - width / 2 - 8)
        let top = insets.top + barSize.height / 2 + 8
        let bottom = max(top, size.height - insets.bottom - barSize.height / 2 - 8)
        return CGPoint(x: min(max(left, size.width * nx + shift.width), right),
                       y: min(max(top, size.height * ny + shift.height), bottom))
    }

    private func handleView(_ size: CGSize, _ insets: EdgeInsets, _ width: CGFloat) -> some View {
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
                        let end = center(size, insets, width: width, shift: value.translation)
                        nx = end.x / max(1, size.width)
                        ny = end.y / max(1, size.height)
                    })
            .accessibilityLabel("Move the key bar")
    }
}
