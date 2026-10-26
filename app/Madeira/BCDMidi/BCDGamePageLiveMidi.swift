// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The game page's Sound section, engine side (round 603): one row, MIDI music, On or Off for this game. It writes the game's own
// config line env.MADEIRA_MIDI (build/ntdll-unix/bcd_midi_ios.c reads it when a game's winmm loads its driver): the line is absent
// for On, the default, and "0" for Off, which brings back what every earlier build did (no MIDI device). Settings > All settings
// > Audio > MIDI music is the same switch for every game; a game's own line wins. Engine-bound like BCDGamePageLive.swift, so the
// preview build leaves it out (the folder is not read by the preview build).

extension BCDGamePageLive {
    static let midiSettingID = "sound.midi"
    static let midiKey = "env.MADEIRA_MIDI"

    /// The section for an installed game with a program of its own.
    func midiGroup(_ entry: LibraryEntry) -> BCDGameSettingGroup {
        let value = GameProfile(windowsPath: entry.windowsPath).get(Self.midiKey) ?? ""
        var choices = [BCDGameChoice(value: "", label: "On (default)"), BCDGameChoice(value: "0", label: "Off")]
        if !choices.contains(where: { $0.value == value }) { choices.append(BCDGameChoice(value: value, label: value)) }   // a value typed into the file by hand
        let setting = BCDGameSetting(
            id: Self.midiSettingID, title: "MIDI music", kind: .choice(choices), value: value, defaultValue: "",
            note: "Many older games play their music as MIDI. BCD plays it through Apple's synthesizer and a General MIDI sound bank, which takes about 17 to 30 MB of memory while a game plays MIDI and nothing otherwise. Off: a game that plays its music as MIDI is silent, as it was before BCD could play it. Takes effect from the game's next start. The same switch for every game: Settings › All settings › Audio.")
        return BCDGameSettingGroup(id: "sound", title: "Sound", symbol: "speaker.wave.2", settings: [setting],
                                   headline: value == "0" ? "MIDI music off" : "MIDI music on")
    }

    /// The Sound section's row: true when `setting` was it.
    func midiSet(_ setting: String, to value: String, for game: BCDGame) -> Bool {
        guard setting == Self.midiSettingID, let entry = entry(for: game) else { return false }
        let file = GameProfile(windowsPath: entry.windowsPath)
        let line: String? = value.isEmpty ? nil : value
        if (file.get(Self.midiKey) ?? "") != (line ?? "") { file.set(Self.midiKey, line) }
        // A game the library holds no entry for yet (a Steam game's first setting) is saved with it, as every other line does.
        if !LibraryModel.shared.entries.contains(where: { $0.id == entry.id }) { LibraryModel.shared.save(entry) }
        return true
    }
}
