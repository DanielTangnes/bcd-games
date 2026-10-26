// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The Sound section's audio rows, engine side (BCDGameSound.swift has the words): they read and write the game's own config lines
// (env.MADEIRA_AUDIO_LEAD_MS, env.MADEIRA_AUDIO_GAIN, env.MADEIRA_AUDIO_RESUME), as the MIDI row does. The default of each is no line.
// Engine-bound like BCDGamePageLive.swift (tools/ui-preview.py, ENGINE_BOUND).

extension BCDGamePageLive {
    /// The rows to add to the Sound section of an installed game with a program of its own.
    func soundSettings(_ entry: LibraryEntry) -> [BCDGameSetting] {
        let file = GameProfile(windowsPath: entry.windowsPath)
        return BCDGameSound.settings(latency: file.get(BCDGameSound.latencyKey) ?? "", volume: file.get(BCDGameSound.volumeKey) ?? "",
                                     resume: file.get(BCDGameSound.resumeKey) ?? "")
    }

    /// The audio rows' settings: true when `setting` was one of them.
    func soundSet(_ setting: String, to value: String, for game: BCDGame) -> Bool {
        guard let key = BCDGameSound.key(setting), let entry = entry(for: game) else { return false }
        let line = BCDGameSound.line(setting, value)
        let file = GameProfile(windowsPath: entry.windowsPath)
        if (file.get(key) ?? "") != (line ?? "") { file.set(key, line) }
        // A game the library holds no entry for yet (a Steam game's first setting) is saved with it, as every other line does.
        if !LibraryModel.shared.entries.contains(where: { $0.id == entry.id }) { LibraryModel.shared.save(entry) }
        return true
    }
}
