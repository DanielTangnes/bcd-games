// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host check for the "Save backups" section's words and rows (app/Madeira/BCDGameSaves.swift), compiled with the page's rules
// and BCDStore.swift by tests/host/check-game-saves.py. Prints "ok" / "FAIL" lines.

import Foundation

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    checks += 1
    if !ok { failures += 1 }
    print((ok ? "ok   " : "FAIL ") + what + (ok || detail.isEmpty ? "" : "\n     " + detail))
}

let t0 = Date(timeIntervalSince1970: 1_792_938_727)
func item(_ i: Int, _ kind: String = "Manual") -> BCDSaveBackupItem {
    BCDSaveBackupItem(id: "2026-10-\(10 + i) 14.32.07 \(kind).zip", date: t0.addingTimeInterval(-Double(i) * 86400), kind: kind, bytes: 48_000 + Int64(i))
}

// A game nothing is known about
do {
    let g = BCDGameSaves.group(BCDSaveBackupsState(folder: "Save Backups › Foo"))
    let ids = g.settings.map(\.id)
    check(g.id == "savebackups" && g.title == "Save backups" && g.parent == nil, "the section is Save backups, a row of Options' own list")
    check(ids == ["savebackups.now", "savebackups.auto", "savebackups.find", "savebackups.places", "savebackups.none"], "rows of a game with no places and no backups", "\(ids)")
    check(g.headline == "No backups yet", "headline: \(g.headline ?? "-")")
    let now = g.settings.first { $0.id == "savebackups.now" }!
    check(now.kind == .action && now.note?.contains("does not know where this game keeps its saves") == true, "Back up now says why it has nothing to copy yet", now.note ?? "")
    let find = g.settings.first { $0.id == "savebackups.find" }!
    check(find.note?.contains("Play the game once") == true, "Find says to play first when no session is known")
    let places = g.settings.first { $0.id == "savebackups.places" }!
    check(places.kind == .info && places.value == "Not known yet", "Where it saves: not known yet")
}

// A game with places and backups, automatic on
do {
    var s = BCDSaveBackupsState(places: ["Documents › My Games › Foo", "AppData › Roaming › Vendor › Foo (Steam Cloud's list)"],
                                backups: [item(0, "Automatic"), item(1, "Manual"), item(2, "Before restore")], older: 0, automatic: true, keep: 5,
                                folder: "Save Backups › Foo", sessionKnown: true)
    var g = BCDGameSaves.group(s)
    let ids = g.settings.map(\.id)
    check(ids.prefix(5) == ["savebackups.now", "savebackups.auto", "savebackups.find", "savebackups.places", "savebackups.forget"], "rows: the actions first, then the places, then Forget", "\(ids)")
    check(ids.suffix(3).allSatisfy { $0.hasPrefix("savebackups.restore.") } && ids.count == 8, "one row per backup", "\(ids)")
    check(g.headline == "3 backups · on close", "headline: \(g.headline ?? "-")")
    let now = g.settings.first { $0.id == "savebackups.now" }!
    check(now.note == "Copies the saves in 2 places into Files › BCD › Save Backups › Foo.", "Back up now says where it copies to", now.note ?? "")
    let auto = g.settings.first { $0.id == "savebackups.auto" }!
    check(auto.value == "1" && auto.defaultValue == "0" && auto.choices.map(\.value) == ["0", "1"], "the automatic switch is off by default, on here")
    check(auto.choices[0].question == nil && auto.choices[1].question?.confirm == "Turn on" && auto.choices[1].question?.destructive == false, "only turning it on asks")
    let q = auto.choices[1].question!
    check(q.message.contains("keeps the newest 5 automatic backups") && q.message.contains("replaces the oldest") && q.message.contains("never removed")
          && q.message.contains("Save Backups › Foo"), "the question says what rotates away and what never does", q.message)
    let first = g.settings.first { $0.id.hasPrefix("savebackups.restore.") }!
    check(first.heading == "Backups" && first.kind == .action && first.title == BCDFormat.dateTime(t0), "the first backup row starts the Backups run, titled by its date", first.title)
    check(first.note == "Automatic · \(BCDFormat.bytes(48_000)) · choose it to put it back", "and says its kind and size", first.note ?? "")
    check(first.question?.destructive == true && first.question?.confirm == "Put back" && first.question?.message.contains("\"Before restore\" backup") == true,
          "a restore asks, and promises the way back", first.question?.message ?? "")
    check(BCDGameSaves.backupName(ofRestore: first.id) == item(0, "Automatic").id, "the backup's file name is in the row's id")
    check(BCDGameSaves.backupName(ofRestore: "savebackups.now") == nil, "other ids are not restores")
    let forget = g.settings.first { $0.id == "savebackups.forget" }!
    check(forget.question?.destructive == true && forget.destructive, "Forget asks")

    // what an action said, and what is running
    s.notes["savebackups.now"] = "Backed up 5 files (48 KB)."
    s.busy = ["savebackups.find"]
    s.notes["savebackups.find"] = "Looking at the files the game changed…"
    g = BCDGameSaves.group(s)
    check(g.settings.first { $0.id == "savebackups.now" }?.note == "Backed up 5 files (48 KB).", "an action's result replaces its note")
    s.notes["savebackups.find"] = nil
    g = BCDGameSaves.group(s)
    check(g.settings.first { $0.id == "savebackups.find" }?.note == "Looking at the files the game changed…", "a running action says so")

    // more backups than the page lists
    s = BCDSaveBackupsState(places: ["Documents › Foo"], backups: (0..<30).map { item($0) }, older: 0, folder: "Save Backups › Foo")
    g = BCDGameSaves.group(s)
    check(g.settings.filter { $0.id.hasPrefix("savebackups.restore.") }.count == 20, "at most 20 backups are listed")
    s.backups = (0..<20).map { item($0) }; s.older = 14
    g = BCDGameSaves.group(s)
    let older = g.settings.first { $0.id == "savebackups.older" }
    check(older?.value == "14 more" && older?.note?.contains("Save Backups › Foo") == true, "the rest are counted and left in Files")
    check(g.headline == "34 backups", "headline counts them all: \(g.headline ?? "-")")
}

// words: nothing of the old name, no purchase talk; the rows never show a Windows user
do {
    let s = BCDSaveBackupsState(places: ["Documents › My Games › Foo"], backups: [item(0)], automatic: true, keep: 5, folder: "Save Backups › Foo", sessionKnown: true)
    let g = BCDGameSaves.group(s)
    var texts: [String] = []
    for setting in g.settings {
        texts += [setting.title, setting.note ?? "", setting.value]
        if let q = setting.question { texts += [q.title, q.message, q.confirm] }
        for c in setting.choices { texts.append(c.label); if let q = c.question { texts += [q.title, q.message, q.confirm] } }
    }
    check(!texts.contains { $0.lowercased().contains("madeira") }, "no \"Madeira\" in the words")
}

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
