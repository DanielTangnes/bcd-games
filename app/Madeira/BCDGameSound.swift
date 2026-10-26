// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The game page's Sound section, three more rows (round 604, F4 and F6): how much audio BCD keeps ready (latency), the game's volume, and
// whether the game's sound is started again after a call or a Bluetooth change. The words and the choices are here (plain values, no
// engine type: the preview app builds this file); the game's own lines are read and written by BCDGamePageLiveSound.swift. Every row's default
// writes nothing: a game keeps exactly the sound it has today until the player chooses.
//
//  - Audio delay: env.MADEIRA_AUDIO_LEAD_MS (build/ntdll-unix/audio_null_ios.c) is how many milliseconds of sound the driver keeps in the
//    game's buffer (10..500, 60 by default). More is safer against crackle, less answers sooner; 0 is the plain 10 ms beat of the oldest builds.
//  - Game volume: env.MADEIRA_AUDIO_GAIN, new in round 604, the game's level at the output in percent (10..200). The phone's volume buttons
//    are iOS's own and still apply.
//  - Keep the sound after interruptions: env.MADEIRA_AUDIO_RESUME, the switch of round 592. Off by default: the logs of 21 sessions that had it
//    on (2026-10-21 to 2026-10-24) show one interruption it recovered from and three where the endpoint never existed (null-mode), and none
//    where it did harm; a Bluetooth change was seen once. Until a device round says more it is a choice, not a default.

enum BCDGameSound {
    static let latencyID = "sound.latency"
    static let volumeID = "sound.volume"
    static let resumeID = "sound.resume"
    static let latencyKey = "env.MADEIRA_AUDIO_LEAD_MS"
    static let volumeKey = "env.MADEIRA_AUDIO_GAIN"
    static let resumeKey = "env.MADEIRA_AUDIO_RESUME"

    static let latencyChoices: [(value: String, label: String)] = [
        ("", "Default (60 ms)"), ("30", "Sooner (30 ms)"), ("120", "More cushion (120 ms)"), ("250", "Most cushion (250 ms)"),
        ("0", "Plain 10 ms beat (the oldest way)"),
    ]
    static let volumeChoices: [(value: String, label: String)] = [
        ("", "Default (100%)"), ("75", "Quieter (75%)"), ("50", "Half (50%)"), ("25", "Quarter (25%)"), ("150", "Louder (150%)"),
    ]

    /// The rows for a game whose own lines hold these values ("" for no line). A value typed into the file by hand stays listed.
    static func settings(latency: String, volume: String, resume: String) -> [BCDGameSetting] {
        func choices(_ list: [(value: String, label: String)], _ current: String, suffix: String) -> [BCDGameChoice] {
            var out = list.map { BCDGameChoice(value: $0.value, label: $0.label) }
            if !out.contains(where: { $0.value == current }) { out.append(BCDGameChoice(value: current, label: current + suffix)) }
            return out
        }
        return [
            BCDGameSetting(
                id: latencyID, title: "Audio delay", kind: .choice(choices(latencyChoices, latency, suffix: " ms")), value: latency, defaultValue: "",
                note: "How much sound BCD keeps ready for the game. More cushion helps when the sound crackles or drops out, and costs a little delay; \"Sooner\" answers faster and may crackle on a busy device. Takes effect from the game's next start."),
            BCDGameSetting(
                id: volumeID, title: "Game volume", kind: .choice(choices(volumeChoices, volume, suffix: "%")), value: volume, defaultValue: "",
                note: "The game's own level at the output, for a game that is much louder or quieter than the rest of your sound. The phone's volume buttons still apply on top. 150% can distort. Takes effect from the game's next start."),
            BCDGameSetting(
                id: resumeID, title: "Keep the sound after interruptions", kind: .toggle, value: resume == "1" ? "1" : "0", defaultValue: "0",
                note: "Experimental. After a phone call, Siri, an alarm or a change of headphones, BCD starts the game's sound again and keeps its audio clock running meanwhile, so a game timed by its sound does not stall. Off: the sound can stay silent until the game restarts. Takes effect from the game's next start."),
        ]
    }

    /// What a choice writes: the value, or nil for the default (the line is removed).
    static func line(_ setting: String, _ value: String) -> String? {
        switch setting {
        case resumeID: return value == "1" ? "1" : nil
        case latencyID, volumeID: return value.isEmpty ? nil : value
        default: return nil
        }
    }

    static func key(_ setting: String) -> String? {
        switch setting {
        case latencyID: return latencyKey
        case volumeID: return volumeKey
        case resumeID: return resumeKey
        default: return nil
        }
    }

    /// A value the player typed into the file by hand is kept only if it is what the driver takes: digits.
    static func plausible(_ setting: String, _ value: String) -> Bool {
        value.isEmpty || (value.count <= 4 && value.allSatisfy(\.isNumber))
    }
}
