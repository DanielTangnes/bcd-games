// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Where round 604's input choices are kept (turbo and macros, the radial menu, the look zone, the
// touch gestures, the Pencil, the controller model). They are how a person plays on a phone or a
// tablet, not a compatibility setting, so they live in the app's own preferences, by the game's
// Windows path, and not in the game's config file: they stay out of the recommended lists and out of
// the fingerprint auto-tune compares (a changed config file there would start a new baseline for a
// tuned game). The gyro aim of round 603 does the same (BCDGyroLive.swift).
//
// Foundation only. A game with no line is a game that has never been touched: every feature reads
// "off" or its documented default from nothing, so a player who does nothing changes nothing.

/// One feature's lines for each game, in a UserDefaults dictionary `bcd.input.<feature>`:
/// `[windowsPath: [line: value]]`. The empty path holds a choice that is for every game.
struct BCDInputPrefs {
    let defaults: UserDefaults
    static let shared = BCDInputPrefs(defaults: .standard)
    private static let prefix = "bcd.input."
    /// The path of the choices that apply to every game.
    static let everyone = ""

    private func all(_ feature: String) -> [String: [String: String]] {
        (defaults.dictionary(forKey: Self.prefix + feature) as? [String: [String: String]]) ?? [:]
    }

    /// The lines of one game (or of everyone) for a feature; empty when it has none.
    func lines(_ feature: String, game: String) -> [String: String] { all(feature)[game] ?? [:] }

    /// One line; an empty value removes it, and a game with no line left is forgotten.
    func set(_ feature: String, game: String, line: String, value: String) {
        var every = all(feature)
        var mine = every[game] ?? [:]
        let was = mine[line]
        mine[line] = value.isEmpty ? nil : value
        guard mine[line] != was else { return }
        every[game] = mine.isEmpty ? nil : mine
        if every.isEmpty {
            defaults.removeObject(forKey: Self.prefix + feature)
        } else {
            defaults.set(every, forKey: Self.prefix + feature)
        }
    }
}
