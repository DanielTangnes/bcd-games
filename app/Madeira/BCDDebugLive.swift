// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The Wine debug channels the in-game menu arms for the next start (round 604, B8; BCDDebugChannels.swift has the presets). The plan is kept in
// the app's preferences so the page can show it; the one-shot file in the temporary folder is what carries it: WineProcessBridge.m reads it
// after the game's own lines, exports its text as WINEDEBUG and removes it, so it applies to one start and the start after it runs as always.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

enum BCDDebugLive {
    private static let key = "bcd.debug.plan"

    static var fileURL: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(BCDDebugOnce.fileName) }

    static var plan: BCDDebugPlan {
        get { BCDDebugPlan.parse(UserDefaults.standard.string(forKey: key)) }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue.stored, forKey: key) }
            write(newValue)
        }
    }

    private static func write(_ plan: BCDDebugPlan) {
        if let text = BCDDebugOnce.contents(presets: plan.presets, timestamps: plan.timestamps) {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
            LogStore.shared.log("[debug-channels] armed for the next start: " + text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// The bridge removes the file when it applies it: a plan whose file is gone has been used, and is forgotten.
    static func reconcile() {
        if !plan.isEmpty, !FileManager.default.fileExists(atPath: fileURL.path) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// What this session's Wine runs with when that is not the usual (a plan was applied at its start), else nil.
    static var runningWithPlan: String? {
        guard let value = getenv("WINEDEBUG").map({ String(cString: $0) }), value != BCDDebugChannels.base,
              value.hasPrefix(BCDDebugChannels.base + ",") else { return nil }
        return value
    }
}
