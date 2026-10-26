// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// Players on the screen (round 604; BCDPlayers.swift has the rules): which controller is each player, assigned by pressing a button
// on it, how hard each player's controller rumbles, and which player the touch controls are. The card sits on the controller screen
// (Settings › Controls › Controllers); the in-game menu has the same choices as a page (BCDInputMenu.swift).

/// What the screens read; BCDPlayersLive.swift fills it and carries out what a person asks.
@MainActor final class BCDPlayersModel: ObservableObject {
    static let shared = BCDPlayersModel()

    @Published private(set) var rows: [BCDPlayerRow] = (0..<BCDPlayerSlots.count).map { BCDPlayerRow(slot: $0) }
    /// The player whose controller is being chosen: the next button pressed on a controller assigns it.
    @Published private(set) var listening: Int?
    @Published private(set) var touchSlot = 0
    weak var actions: BCDPlayersActions?

    var connected: Int { rows.filter { $0.name != nil }.count }
    var snapshot: BCDPlayersSnapshot { BCDPlayersSnapshot(rows: rows, listening: listening, touchSlot: touchSlot) }

    func update(names: [String?], settings: BCDPlayerSettings, listening: Int?) {
        let now = (0..<BCDPlayerSlots.count).map { BCDPlayerRow(slot: $0, name: $0 < names.count ? names[$0] : nil, rumble: settings.rumblePercent($0)) }
        if now != rows { rows = now }
        if self.listening != listening { self.listening = listening }
        if touchSlot != settings.touchSlot { touchSlot = settings.touchSlot }
    }

    /// A sample for the preview app.
    func preview(names: [String?], rumble: [Int: Int] = [:], touchSlot: Int = 0, listening: Int? = nil) {
        var settings = BCDPlayerSettings()
        settings.rumble = rumble
        settings.touchSlot = touchSlot
        update(names: names, settings: settings, listening: listening)
    }
}

/// The card: four players, each with its controller, an Assign button and its rumble; the touch controls' player; Reset.
struct BCDPlayersCard: View {
    @ObservedObject var model: BCDPlayersModel
    let roomy: Bool
    let padding: CGFloat

    @MainActor init(model: BCDPlayersModel? = nil, roomy: Bool = false, padding: CGFloat = 14) {
        _model = ObservedObject(wrappedValue: model ?? .shared)
        self.roomy = roomy
        self.padding = padding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BCDEyebrow(text: "Players")
            Text("Press a button on a controller to make it Player 1, 2, 3 or 4. Games see up to four. Nothing is remembered until you choose; "
                 + "until then each controller takes the first free player as it connects.")
                .font(BCDStyle.body(roomy ? 14 : 12)).foregroundStyle(BCDStyle.textSoft).fixedSize(horizontal: false, vertical: true)
            ForEach(model.rows) { row in
                playerRow(row)
                if row.slot < BCDPlayerSlots.count - 1 { Rectangle().fill(BCDStyle.stroke).frame(height: 1) }
            }
            Rectangle().fill(BCDStyle.stroke).frame(height: 1)
            touchRow
            Button { model.actions?.reset() } label: {
                Text("Back to first come, first served").font(BCDStyle.label(roomy ? 15 : 14)).foregroundStyle(BCDStyle.lavender)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.plain)
            .bcdFocusable("controllers.players.reset", cornerRadius: 12) { model.actions?.reset() }
        }
        .bcdCard(padding: padding)
    }

    private func playerRow(_ row: BCDPlayerRow) -> some View {
        let listening = model.listening == row.slot
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("P\(row.slot + 1)")
                    .font(BCDStyle.label(roomy ? 16 : 14)).foregroundStyle(BCDStyle.lavender)
                    .frame(width: roomy ? 46 : 40, height: roomy ? 46 : 40)
                    .background(BCDStyle.surfaceRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(BCDStyle.label(roomy ? 17 : 15))
                    Text(listening ? "Press a button on the controller now" : (row.name ?? "No controller"))
                        .font(BCDStyle.body(roomy ? 14 : 12))
                        .foregroundStyle(listening ? BCDStyle.fuchsia : BCDStyle.textSoft).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                chip(listening ? "Cancel" : "Assign", id: "controllers.players.\(row.slot).assign") {
                    if listening { model.actions?.cancelAssign() } else { model.actions?.beginAssign(slot: row.slot) }
                }
            }
            HStack(spacing: 8) {
                Text("Rumble").font(BCDStyle.body(roomy ? 14 : 12)).foregroundStyle(BCDStyle.textSoft)
                Spacer(minLength: 6)
                chip(BCDPlayerWords.rumble(row.rumble), id: "controllers.players.\(row.slot).rumble") {
                    model.actions?.setRumble(slot: row.slot, percent: Self.nextRumble(after: row.rumble))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var touchRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The touch controls play as").font(BCDStyle.label(roomy ? 16 : 14))
                Text("Player 1 unless you choose another: a controller can then be Player 1 beside you.")
                    .font(BCDStyle.body(roomy ? 13 : 12)).foregroundStyle(BCDStyle.textSoft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            chip(BCDPlayerSlots.title(model.touchSlot), id: "controllers.players.touch") {
                model.actions?.setTouchPlayer(slot: (model.touchSlot + 1) % BCDPlayerSlots.count)
            }
        }
    }

    private func chip(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(BCDStyle.label(roomy ? 15 : 14)).foregroundStyle(BCDStyle.text)
                .padding(.horizontal, 14).frame(minHeight: 34)
                .background(BCDStyle.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(BCDStyle.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .bcdFocusable(id, cornerRadius: 17, action: action)
    }

    /// Full, 75 %, 50 %, 25 %, Off, and round again.
    static func nextRumble(after percent: Int) -> Int {
        let list = BCDPlayerSettings.rumbleChoices
        guard let i = list.firstIndex(of: percent) else { return 100 }
        return list[(i + 1) % list.count]
    }
}
