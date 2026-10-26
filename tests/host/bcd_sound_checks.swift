// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// The game page's three audio rows (app/Madeira/BCDGameSound.swift), compiled with the page's rules by tests/host/check-audio-gain.py.

import Foundation

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "ok   " : "FAIL ") + what + (ok || detail.isEmpty ? "" : "\n     " + detail))
    if !ok { failures += 1 }
}

@main enum Run {
    static func main() {
        let rows = BCDGameSound.settings(latency: "", volume: "", resume: "")
        check("three rows: audio delay, game volume, keep the sound after interruptions", rows.map(\.id) == ["sound.latency", "sound.volume", "sound.resume"])
        check("every row starts at its default (no line is written for a game that did nothing)", rows.allSatisfy(\.isDefault))
        check("the delay choices are the driver's: default 60, 30, 120, 250 and 0 (the old beat)", rows[0].choices.map(\.value) == ["", "30", "120", "250", "0"]
              && Set(rows[0].choices.map(\.value)).isSubset(of: ["", "30", "120", "250", "0"]))
        check("the volume choices are percent inside 10..200", rows[1].choices.map(\.value) == ["", "75", "50", "25", "150"]
              && rows[1].choices.compactMap { Int($0.value) }.allSatisfy { (10...200).contains($0) })
        check("the resume switch is a toggle, off by default", rows[2].kind == .toggle && rows[2].value == "0" && rows[2].defaultValue == "0")
        check("a value typed into the file by hand stays listed", BCDGameSound.settings(latency: "90", volume: "60", resume: "")[0].choices.last?.value == "90"
              && BCDGameSound.settings(latency: "", volume: "60", resume: "")[1].choices.last?.label == "60%")
        check("a changed row shows as changed", BCDGameSound.settings(latency: "120", volume: "", resume: "1")[0].changed
              && BCDGameSound.settings(latency: "120", volume: "", resume: "1")[2].changed)
        check("the default choice removes the line, a choice writes it",
              BCDGameSound.line("sound.latency", "") == nil && BCDGameSound.line("sound.latency", "120") == "120"
              && BCDGameSound.line("sound.volume", "") == nil && BCDGameSound.line("sound.volume", "50") == "50"
              && BCDGameSound.line("sound.resume", "0") == nil && BCDGameSound.line("sound.resume", "1") == "1" && BCDGameSound.line("sound.other", "1") == nil)
        check("each row names its key", BCDGameSound.key("sound.latency") == "env.MADEIRA_AUDIO_LEAD_MS" && BCDGameSound.key("sound.volume") == "env.MADEIRA_AUDIO_GAIN"
              && BCDGameSound.key("sound.resume") == "env.MADEIRA_AUDIO_RESUME" && BCDGameSound.key("sound.midi") == nil)
        check("only digits are plausible", BCDGameSound.plausible("x", "60") && !BCDGameSound.plausible("x", "6a") && !BCDGameSound.plausible("x", "12345") && BCDGameSound.plausible("x", ""))
        check("the resume row says it is experimental and what Off means", rows[2].note?.hasPrefix("Experimental.") == true && rows[2].note?.contains("Off:") == true)
        print(failures == 0 ? "bcd_sound_checks: PASS" : "bcd_sound_checks: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
