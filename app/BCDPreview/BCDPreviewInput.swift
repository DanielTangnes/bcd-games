// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

/// Round 604's input screens on sample values, for the preview app's photographs (tools/ui-preview.py):
///   -BCDTab input-players          the Players card (Settings › Controls › Controllers) on sample controllers
///   -BCDTab input-radial[-open|-slide|-left]   the radial menu's button, its ring open, a finger over one slot, the button on the left
/// A picture of a game stands in for the running game. Only the preview app compiles this file.
struct BCDPreviewInputRoot: View {
    let spec: String
    let store: BCDStore
    @StateObject private var radial = BCDRadialModel()

    private var game: BCDGame {
        store.games.first { $0.id == "367520" } ?? BCDGame(id: "sample", title: "Sample Game", store: .local, state: .ready)
    }

    var body: some View {
        Group {
            if spec == "input-players" {
                ScrollView {
                    BCDPlayersCard(roomy: false, padding: 14).padding(14)
                }
                .background { BCDBackdrop() }
                .preferredColorScheme(.dark)
            } else {
                ZStack {
                    Color.black
                    BCDGameArt(game: game, kind: .hero, showTitle: false)
                    BCDRadialLayer(model: radial, report: { _ in })
                }
                .ignoresSafeArea()
                .onAppear {
                    var settings = BCDRadialSettings()
                    settings.isOn = true
                    if spec == "input-radial-left" { settings.place = .leftMiddle }
                    settings.slots[5] = .chord([0x12], 0x09)
                    settings.slots[6] = .click(.right)
                    settings.slots[7] = nil
                    radial.settings = settings
                    if spec == "input-radial-open" { radial.preview(open: true, highlighted: nil) }
                    if spec == "input-radial-slide" { radial.preview(open: true, highlighted: 2) }
                }
            }
        }
    }
}
