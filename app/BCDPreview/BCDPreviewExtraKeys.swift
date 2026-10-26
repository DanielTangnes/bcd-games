// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

/// The extra keys on sample values, for the preview app's photographs (tools/ui-preview.py):
///   -BCDTab keybar[-held|-fn]    the floating key bar over a game (held: Ctrl held for one key and Alt locked), or the
///                                keyboard bar's second page (fn: Ctrl held)
/// A picture of a game stands in for the running game. Only the preview app compiles this file.
struct BCDPreviewExtraKeysScreens: ViewModifier {
    let store: BCDStore

    static func handles(_ tab: String) -> Bool { tab.hasPrefix("keybar") }

    func body(content: Content) -> some View {
        let tab = UserDefaults.standard.string(forKey: "BCDTab") ?? "home"
        if Self.handles(tab) {
            content.hidden().overlay { BCDPreviewExtraKeysStage(spec: tab, store: store).ignoresSafeArea() }
        } else {
            content
        }
    }
}

private struct BCDPreviewExtraKeysStage: View {
    let spec: String
    let store: BCDStore
    @StateObject private var model = BCDExtraKeyBarModel()
    @StateObject private var keyboard = BCDKeyboardBarModel()

    private var game: BCDGame {
        store.games.first { $0.id == "367520" } ?? BCDGame(id: "sample", title: "Sample Game", store: .local, state: .ready)
    }

    var body: some View {
        ZStack {
            Color.black
            BCDGameArt(game: game, kind: .hero, showTitle: false)
            if spec == "keybar-fn" {
                VStack {
                    Spacer()
                    BCDKeyboardBar(model: keyboard, press: { _ in }, done: {})
                    Rectangle().fill(Color(white: 0.17)).frame(height: 180)
                        .overlay(Text(verbatim: "iOS keyboard").font(.caption).foregroundStyle(.secondary))
                }
                .ignoresSafeArea()
            } else {
                BCDExtraKeyBarLayer(model: model, press: { _ in }, longPress: { _ in }, close: {}, report: { _ in })
            }
        }
        .onAppear {
            switch spec {
            case "keybar-held": model.states = [BCDVK.ctrl: .once, BCDVK.alt: .locked]
            case "keybar-fn": keyboard.secondPage = true; keyboard.latched = ["ctrl"]
            default: break
            }
        }
    }
}
