// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
import Metal

// "Look like this GPU" at a launch (BCDGPUCards.swift has the cards and the rules). The game's line
// `gpu-card` (else bcd.cfg's, so one line can serve every game) picks a card; this puts it into the
// launch the way every other per-game choice gets in: DXMT's options for DXGI and Direct3D 9
// (ContentView composes DXMT_CONFIG and calls this just before it sets it) and the environment
// win32u reads for Windows' own adapter (build/win32u-unix/sysparams_ios.c). It runs once per
// launch, on the launch worker, and does nothing at all when no card is chosen.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

enum BCDGPUCardsLive {
    /// The card the launch asks for, nil when none is chosen (or the line names a card this build does not know).
    static func chosen() -> (card: BCDGPUCard?, word: String) {
        let word = (MadeiraConfig.gameValue("gpu-card") ?? MadeiraConfig.get("gpu-card") ?? "").trimmingCharacters(in: .whitespaces)
        return (BCDGPUCards.card(word), word)
    }

    /// Puts the launch's card into `options` (the DXMT options so far) and the environment.
    static func apply(to options: inout [String]) {
        let (card, word) = chosen()
        guard let card else {
            if !word.isEmpty { LogStore.shared.log("[gpu-card] \"\(word)\" is not a card this build knows: the game sees what it always saw") }
            return
        }
        let merged = BCDGPUCards.merged(options, with: card)
        options = merged.options
        let env = BCDGPUCards.environment(card, nativeName: card.isApple ? MTLCreateSystemDefaultDevice()?.name : nil)
        for (name, value) in env.set { setenv(name, value, 1) }
        for name in env.unset { unsetenv(name) }
        LogStore.shared.log("[gpu-card] \(card.id): \(env.set["MADEIRA_GPU_NAME"] ?? "BCD's own Apple GPU") \(card.vendorHex):\(card.deviceHex)"
                            + " in DXGI, Direct3D 9 and Windows; nvapi=\(card.isNVIDIA ? 1 : 0)"
                            + (merged.replaced > 0 ? "; \(merged.replaced) adapter option\(merged.replaced == 1 ? "" : "s") of the game's DXMT lines replaced" : "")
                            + (merged.namesDropped ? "; the names left out, DXMT's \(BCDGPUCards.dxmtConfigLimit)-character limit" : ""))
    }
}
