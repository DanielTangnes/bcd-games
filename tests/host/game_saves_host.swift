// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host check for BCD's per-game save backups (app/Madeira/BCDSaveBackups/, BCDGameSaves.swift): compiled with the rules,
// the file side and the job, and the production zip writer and reader (cut out of SavesAndShortcuts.swift by
// tests/host/check-game-saves.py), run on a prefix built in a scratch folder. Prints "ok" / "FAIL" lines.

import Foundation

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    checks += 1
    if !ok { failures += 1 }
    print((ok ? "ok   " : "FAIL ") + what + (ok || detail.isEmpty ? "" : "\n     " + detail))
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("bcd-game-saves-\(UUID().uuidString)")
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

func write(_ url: URL, _ text: String, modified: Date? = nil) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.data(using: .utf8)!.write(to: url)
    if let modified { try! fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}
func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }

let utc = TimeZone(secondsFromGMT: 0)!

// ------------------------------------------------------------------------------ dates made from numbers
do {
    var cal = Calendar(identifier: .gregorian)
    var allRight = true
    var detail = ""
    for zone in [TimeZone(secondsFromGMT: 0)!, TimeZone(secondsFromGMT: 3 * 3600)!, TimeZone(secondsFromGMT: -5 * 3600 - 1800)!] {
        cal.timeZone = zone
        var t: TimeInterval = 0
        while t < 4_200_000_000 {
            let date = Date(timeIntervalSince1970: t)
            let c = GameSaveRules.civil(date, offset: zone.secondsFromGMT(for: date))
            let f = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            if (c.year, c.month, c.day, c.hour, c.minute, c.second) != (f.year!, f.month!, f.day!, f.hour!, f.minute!, f.second!) {
                allRight = false; detail = "\(t) in \(zone.identifier): \(c) vs \(f)"; break
            }
            if GameSaveRules.epoch(c, offset: zone.secondsFromGMT(for: date)) != t.rounded(.down) {
                allRight = false; detail = "epoch \(t) in \(zone.identifier)"; break
            }
            t += 1_234_567.0 + 86_399   // steps that land on every month, hour and leap day over 130 years
        }
    }
    check(allRight, "dates made from numbers agree with Foundation's calendar in three time zones, 1970-2100", detail)
    check(GameSaveRules.isoUTC(Date(timeIntervalSince1970: 1_792_938_727)) == "2026-10-25T14:32:07Z", "an ISO stamp",
          GameSaveRules.isoUTC(Date(timeIntervalSince1970: 1_792_938_727)))
}

// ------------------------------------------------------------------------------ names
do {
    let date = Date(timeIntervalSince1970: 1_792_938_727)   // 2026-10-25 14:32:07 UTC
    let name = GameSaveRules.backupName(date: date, kind: .manual, timeZone: utc)
    check(name == "2026-10-25 14.32.07 Manual.zip", "a backup's name", name)
    let istanbul = TimeZone(secondsFromGMT: 3 * 3600)!
    check(GameSaveRules.backupName(date: date, kind: .beforeRestore, timeZone: istanbul) == "2026-10-25 17.32.07 Before restore.zip", "local time in the name")
    let second = GameSaveRules.backupName(date: date, kind: .manual, taken: [name], timeZone: utc)
    let third = GameSaveRules.backupName(date: date, kind: .manual, taken: [name, second], timeZone: utc)
    check(second == "2026-10-25 14.32.07 Manual 2.zip" && third == "2026-10-25 14.32.07 Manual 3.zip", "a taken name gets a number", "\(second) / \(third)")
    for kind in GameSaveKind.allCases {
        for zone in [utc, istanbul, TimeZone(identifier: "America/New_York")!] {
            let n = GameSaveRules.backupName(date: date, kind: kind, timeZone: zone)
            let parsed = GameSaveRules.parseBackupName(n, timeZone: zone)
            check(parsed?.kind == kind && parsed?.date == date, "name \(n) reads back (\(zone.identifier))", "\(String(describing: parsed))")
        }
    }
    check(GameSaveRules.parseBackupName("2026-10-25 14.32.07 Manual 3.zip", timeZone: utc)?.kind == .manual, "a numbered name reads back")
    for bad in ["notes.zip", "2026-10-25 14.32.07 Weekly.zip", "2026-13-25 14.32.07 Manual.zip", "2026-10-25 14.32.07 Manual.txt", ".partial-ABC.zip",
                "2026-10-25 14.32.07 Manual x.zip", "2026-1-25 14.32.07 Manual.zip", "2026-10-25 25.32.07 Manual.zip"] {
        check(GameSaveRules.parseBackupName(bad, timeZone: utc) == nil, "not a backup name: \(bad)")
    }
    check(GameSaveRules.safeFolderName("Half-Life: Alyx / VR?") == "Half-Life- Alyx - VR-", "a game's folder name", GameSaveRules.safeFolderName("Half-Life: Alyx / VR?"))
    check(GameSaveRules.safeFolderName("  ... ") == "Game" && GameSaveRules.safeFolderName(String(repeating: "x", count: 200)).count == 80, "empty and long titles")
}

// ------------------------------------------------------------------------------ rotation
do {
    var list: [(name: String, date: Date, kind: GameSaveKind)] = []
    for i in 0..<8 { list.append(("auto\(i)", Date(timeIntervalSince1970: 1000 + Double(i)), .automatic)) }
    list.append(("manual-old", Date(timeIntervalSince1970: 1), .manual))
    list.append(("before-old", Date(timeIntervalSince1970: 2), .beforeRestore))
    let gone = GameSaveRules.toRemove(list, keep: 5)
    check(Set(gone) == ["auto0", "auto1", "auto2"], "the automatic backups beyond the newest 5 go, oldest first; manual ones and copies before a restore never do", "\(gone)")
    check(GameSaveRules.toRemove(list, keep: 100).isEmpty, "keep is clamped (20 at most): all 8 stay")
    check(Set(GameSaveRules.toRemove(list, keep: 0)) == Set(["auto0", "auto1", "auto2", "auto3", "auto4", "auto5"]), "keep is clamped (2 at least)")
    check(GameSaveRules.toRemove([("m", Date(), .manual)], keep: 5) == [], "nothing automatic: nothing goes")
}

// ------------------------------------------------------------------------------ paths
do {
    check(GameSaveRules.safeParts("users/u/Documents/My Games/Foo/s.sav")?.count == 6, "a plain path is safe")
    for bad in ["../evil.txt", "/abs/x", "\\abs\\x", "a/../b", "a//b", "a/./b", "C:/Windows/x", "users/u/x\0y", "", "a/b/"] {
        check(GameSaveRules.safeParts(bad) == nil, "refused entry path: \(bad.replacingOccurrences(of: "\0", with: "NUL"))")
    }
    check(GameSaveRules.logPath("users/tester/AppData/Roaming/Foo/s.dat") == "users/<user>/AppData/Roaming/Foo/s.dat", "the log never names the Windows user")
    check(GameSaveRules.logPath("users/Public/Documents/Foo") == "users/Public/Documents/Foo", "Public stays")
}

// ------------------------------------------------------------------------------ roots from changed files
do {
    func f(_ p: String) -> GameSaveFile { GameSaveFile(path: p, size: 10, modified: 5) }
    let users = ["tester"]
    let install = "Program Files (x86)/Steam/steamapps/common/Foo"
    let changed = [
        f("users/tester/Documents/My Games/Skyrim/Saves/save1.ess"), f("users/tester/Documents/My Games/Skyrim/Saves/autosave.ess"),
        f("users/tester/Documents/My Games/Skyrim/Skyrim.ini"),
        f("users/tester/AppData/Roaming/Vendor/Game/profile/slot1/data.bin"),
        f("users/tester/AppData/LocalLow/Studio/Game/prefs.xml"),
        f("users/tester/Documents/loose.sav"),
        f("users/tester/AppData/Local/Temp/junk.dat"), f("users/tester/AppData/Local/Microsoft/Windows/x.dat"),
        f("users/tester/AppData/Local/Vendor2/Game2/crash.dmp"), f("users/tester/AppData/Local/Vendor2/Game2/logs/a.txt"),
        f("users/tester/AppData/Local/NVIDIA/GLCache/x.bin"),
        f("users/Public/Documents/Shared/Game/world.dat"),
        f("ProgramData/Studio/Game/settings.cfg"),
        f(install + "/SaveGames/slot1.sav"), f(install + "/SaveGames/slot2.sav"), f(install + "/Foo.exe"), f(install + "/Data/big.pak"),
        f(install + "/config.ini"), f(install + "/Logs/session.txt"), f(install + "/Mods/pack/inner/deep/data.dat"),
        f("Windows/system32/x.dll"), f("users/tester/Desktop/other.txt"),
    ]
    let roots = GameSaveRules.roots(changed: changed, users: users, install: install, source: .played)
    let paths = Set(roots.map(\.path))
    let want: Set<String> = [
        "users/tester/Documents/My Games/Skyrim",
        "users/tester/AppData/Roaming/Vendor/Game",
        "users/tester/AppData/LocalLow/Studio/Game",
        "users/tester/Documents/loose.sav",
        "users/Public/Documents/Shared/Game",
        "ProgramData/Studio/Game",
        install + "/SaveGames",
        install + "/config.ini",
        install + "/Mods/pack",
    ]
    check(paths == want, "roots: a deep path stops at two folders below its base, a file straight in a base is a file root, caches, logs, program files and other places are left out",
          "extra: \(paths.subtracting(want).sorted()) missing: \(want.subtracting(paths).sorted())")
    check(roots.first(where: { $0.path.hasSuffix("loose.sav") })?.isFile == true && roots.filter { $0.isFile }.count == 2, "file roots are files")
    let inGameFolder = GameSaveRules.roots(changed: [f(install + "/SaveGames/slot1.sav")], users: users, install: nil, source: .played)
    check(inGameFolder.isEmpty, "without a game folder the game's folder is not searched")
    let folded = GameSaveRules.roots(changed: [f("USERS/Tester/documents/my games/Foo/a.sav")], users: ["tester"], install: nil, source: .played)
    check(folded.map(\.path) == ["USERS/Tester/documents/my games/Foo"], "case is ignored in matching, kept in the root", "\(folded.map(\.path))")
    let huge = GameSaveRules.roots(changed: [GameSaveFile(path: "users/tester/Documents/Foo/a.sav", size: GameSaveRules.maxFileBytes + 1, modified: 1)],
                                   users: users, install: nil, source: .played)
    check(huge.isEmpty, "a file over the limit makes no root")

    // merge: the broader root keeps, the same place twice is one, the first source stays
    let a = GameSaveRoot(path: "users/t/Documents/Game/Saves", isFile: false, source: .played)
    let b = GameSaveRoot(path: "users/t/Documents/Game", isFile: false, source: .steamCloud)
    let c = GameSaveRoot(path: "USERS/T/documents/game", isFile: false, source: .played)
    let d = GameSaveRoot(path: "users/t/Documents/Game/readme.txt", isFile: true, source: .played)
    let merged = GameSaveRules.merge([a, d], [b, c])
    check(merged.count == 1 && merged[0].path == "users/t/Documents/Game", "a root inside another is dropped", "\(merged)")
    check(GameSaveRules.merge([a], [a]) == [a], "merging the same root twice is a no-op")
    let fileInside = GameSaveRules.merge([GameSaveRoot(path: "users/t/Documents/Game", isFile: true, source: .played)],
                                         [GameSaveRoot(path: "users/t/Documents/Game/x", isFile: false, source: .played)])
    check(fileInside.count == 2, "a file root does not swallow a path below it")

    // what the player reads
    check(GameSaveRules.display(GameSaveRoot(path: "users/tester/Documents/My Games/Skyrim", isFile: false, source: .played)) == "Documents › My Games › Skyrim", "display: no user name")
    check(GameSaveRules.display(GameSaveRoot(path: "users/Public/Documents/X", isFile: false, source: .played)) == "Public › Documents › X", "display: Public")
    check(GameSaveRules.display(GameSaveRoot(path: install + "/SaveGames", isFile: false, source: .played), install: install) == "Game folder › SaveGames", "display: the game's folder")
    check(GameSaveRules.display(GameSaveRoot(path: "ProgramData/Studio", isFile: false, source: .played)) == "ProgramData › Studio", "display: ProgramData")
}

// ------------------------------------------------------------------------------ signature
do {
    let a = [GameSaveFile(path: "a/x", size: 1, modified: 10), GameSaveFile(path: "b/y", size: 2, modified: 20)]
    let reordered = [a[1], a[0]]
    var bigger = a; bigger[1].size = 3
    var newer = a; newer[0].modified = 11
    check(GameSaveRules.signature(a) == GameSaveRules.signature(reordered), "the signature does not depend on order")
    check(GameSaveRules.signature(a) != GameSaveRules.signature(bigger) && GameSaveRules.signature(a) != GameSaveRules.signature(newer), "size and time change it")
}

// ------------------------------------------------------------------------------ a prefix on disk
let drive = scratch.appendingPathComponent("drive_c")
let backups = scratch.appendingPathComponent("Save Backups")
let user = drive.appendingPathComponent("users/tester")
let install = "Program Files/Foo"
let sessionStart = Date(timeIntervalSinceNow: -3600)
let old = Date(timeIntervalSinceNow: -86400)
let during = Date(timeIntervalSinceNow: -1800)

write(user.appendingPathComponent("Documents/My Games/Foo/Saves/slot1.sav"), "slot one", modified: during)
write(user.appendingPathComponent("Documents/My Games/Foo/Saves/slot2.sav"), "slot two", modified: during)
write(user.appendingPathComponent("Documents/My Games/Foo/Foo.ini"), "[Foo]", modified: during)
write(user.appendingPathComponent("Documents/My Games/Other/unrelated.sav"), "other game", modified: old)
write(user.appendingPathComponent("AppData/Roaming/Vendor/Foo/profile.dat"), "profile", modified: during)
write(user.appendingPathComponent("AppData/Local/Temp/junk.tmp"), "junk", modified: during)
write(user.appendingPathComponent("AppData/Local/Microsoft/cache.bin"), "ms", modified: during)
write(user.appendingPathComponent("AppData/Local/Foo/crash.dmp"), "dump", modified: during)
write(drive.appendingPathComponent(install + "/Foo.exe"), "MZ", modified: during)
write(drive.appendingPathComponent(install + "/Save/game.sav"), "install save", modified: during)
write(drive.appendingPathComponent(install + "/data/level1.dat"), "level", modified: old)
write(drive.appendingPathComponent(install + "/logs/a.log"), "log", modified: during)

do {
    check(GameSaveBackups.users(drive: drive) == ["tester"], "the Windows users of the prefix")
    let scan = GameSaveBackups.changedFiles(since: sessionStart, drive: drive, users: ["tester"], install: install)
    let names = Set(scan.files.map(\.path))
    check(names == ["users/tester/Documents/My Games/Foo/Saves/slot1.sav", "users/tester/Documents/My Games/Foo/Saves/slot2.sav",
                    "users/tester/Documents/My Games/Foo/Foo.ini", "users/tester/AppData/Roaming/Vendor/Foo/profile.dat",
                    "users/tester/AppData/Local/Foo/crash.dmp", "Program Files/Foo/Foo.exe", "Program Files/Foo/Save/game.sav"],
          "the scan finds the files modified since the start (caches and logs folders skipped; extension noise is the rules' job)", "\(names.sorted())")
    check(GameSaveBackups.changedFiles(since: Date(timeIntervalSinceNow: 60), drive: drive, users: ["tester"], install: install).files.isEmpty, "nothing changed after the future")
    let roots = GameSaveRules.roots(changed: scan.files, users: ["tester"], install: install, source: .played)
    check(Set(roots.map(\.path)) == ["users/tester/Documents/My Games/Foo", "users/tester/AppData/Roaming/Vendor/Foo", "Program Files/Foo/Save"],
          "the roots of the session", "\(roots.map(\.path))")
}

let rootsOfFoo = GameSaveRules.merge([], [
    GameSaveRoot(path: "users/tester/Documents/My Games/Foo", isFile: false, source: .played),
    GameSaveRoot(path: "users/tester/AppData/Roaming/Vendor/Foo", isFile: false, source: .played),
    GameSaveRoot(path: "Program Files/Foo/Save", isFile: false, source: .played),
])
let when = Date(timeIntervalSince1970: 1_792_938_727)

do {
    let collected = GameSaveBackups.collect(roots: rootsOfFoo, drive: drive)
    check(collected.files.count == 5 && !collected.tooBig, "collect: every file of every root (5)", "\(collected.files.map(\.path))")
    // case-insensitive follow
    let odd = GameSaveBackups.collect(roots: [GameSaveRoot(path: "USERS/Tester/documents/MY GAMES/foo", isFile: false, source: .played)], drive: drive)
    check(odd.files.count == 3 && odd.files.allSatisfy { $0.path.hasPrefix("users/tester/Documents/My Games/Foo") }, "collect follows a differently spelled root and reports the disk's spelling", "\(odd.files.map(\.path))")

    let made = try! GameSaveBackups.backUp(title: "Foo: The Game", roots: rootsOfFoo, drive: drive, kind: .manual, now: when, into: backups, timeZone: utc)
    check(made.files == 5 && made.url.lastPathComponent == "2026-10-25 14.32.07 Manual.zip" && made.url.deletingLastPathComponent().lastPathComponent == "Foo- The Game",
          "a manual backup: 5 files, named by its time, in the game's folder", "\(made)")
    let zip = try! SaveZipReader(url: made.url)
    let entryNames = Set(zip.entries.map(\.name))
    check(entryNames == ["users/tester/Documents/My Games/Foo/Saves/slot1.sav", "users/tester/Documents/My Games/Foo/Saves/slot2.sav",
                         "users/tester/Documents/My Games/Foo/Foo.ini", "users/tester/AppData/Roaming/Vendor/Foo/profile.dat",
                         "Program Files/Foo/Save/game.sav", "bcd-saves.json"], "the zip holds the files by their path from drive_c, and a note", "\(entryNames.sorted())")
    let slot = zip.entries.first { $0.name.hasSuffix("slot1.sav") }!
    check(String(data: try! zip.extract(slot), encoding: .utf8) == "slot one", "and their bytes")
    check(GameSaveBackups.roots(ofBackup: made.url).count == 3, "the note names the roots")
    let listed = GameSaveBackups.list(title: "Foo: The Game", in: backups, timeZone: utc)
    check(listed.count == 1 && listed[0].kind == .manual && listed[0].date == when && listed[0].bytes > 0, "the list shows it")

    // a second backup in the same second is a new file, the first untouched
    let again = try! GameSaveBackups.backUp(title: "Foo: The Game", roots: rootsOfFoo, drive: drive, kind: .manual, now: when, into: backups, timeZone: utc)
    check(again.url.lastPathComponent == "2026-10-25 14.32.07 Manual 2.zip" && fm.fileExists(atPath: made.url.path), "a name taken is never written over")
    check(((try? fm.contentsOfDirectory(atPath: made.url.deletingLastPathComponent().path)) ?? []).allSatisfy { !$0.hasPrefix(".partial") }, "no partial file is left")

    // restore: the files go back, other files stay, and what was there is the caller's to keep first
    write(user.appendingPathComponent("Documents/My Games/Foo/Saves/slot1.sav"), "CHANGED")
    write(user.appendingPathComponent("Documents/My Games/Foo/Saves/slot3.sav"), "a newer slot the backup does not hold")
    try! fm.removeItem(at: user.appendingPathComponent("AppData/Roaming/Vendor/Foo/profile.dat"))
    let r = try! GameSaveBackups.restore(made.url, drive: drive)
    check(r.written == 5 && r.refused == 0, "restore writes the 5 files", "\(r)")
    check(read(user.appendingPathComponent("Documents/My Games/Foo/Saves/slot1.sav")) == "slot one", "a changed file is back as it was")
    check(read(user.appendingPathComponent("AppData/Roaming/Vendor/Foo/profile.dat")) == "profile", "a removed file is back")
    check(read(user.appendingPathComponent("Documents/My Games/Foo/Saves/slot3.sav")) == "a newer slot the backup does not hold", "a file the backup does not hold stays")
    check(read(drive.appendingPathComponent("Program Files/Foo/Save/game.sav")) == "install save", "the game folder's save is back")
    check(!fm.fileExists(atPath: drive.appendingPathComponent("bcd-saves.json").path), "the note is not written into the prefix")

    // a backup made elsewhere with hostile entry names: nothing outside drive_c, nothing absolute
    let evilURL = scratch.appendingPathComponent("evil.zip")
    let evil = try! SaveZipWriter(url: evilURL)
    try! evil.add(name: "../outside.txt", data: Data("x".utf8))
    try! evil.add(name: "/etc/outside2.txt", data: Data("x".utf8))
    try! evil.add(name: "C:/outside3.txt", data: Data("x".utf8))
    try! evil.add(name: "users/tester/Documents/ok.txt", data: Data("ok".utf8))
    try! evil.add(name: "a/../../outside4.txt", data: Data("x".utf8))
    try! evil.finish()
    let e = try! GameSaveBackups.restore(evilURL, drive: drive)
    check(e.written == 1 && e.refused == 4, "hostile entry names are refused (4), the plain one is written", "\(e)")
    check(!fm.fileExists(atPath: scratch.appendingPathComponent("outside.txt").path) && !fm.fileExists(atPath: drive.appendingPathComponent("../outside.txt").path),
          "nothing was written above drive_c")
    check(read(user.appendingPathComponent("Documents/ok.txt")) == "ok", "the plain entry is in place")
    let none = scratch.appendingPathComponent("none.zip")
    let emptyZip = try! SaveZipWriter(url: none); try! emptyZip.add(name: GameSaveBackups.manifestName, data: Data("{}".utf8)); try! emptyZip.finish()
    check((try? GameSaveBackups.restore(none, drive: drive)) == nil, "a backup with no files is an error, not a silent success")
}

// ------------------------------------------------------------------------------ nothing to back up, too much to back up
do {
    var threw = false
    do { _ = try GameSaveBackups.backUp(title: "Empty", roots: [], drive: drive, kind: .manual, into: backups) } catch { threw = true }
    check(threw, "no roots: an error and no folder", "")
    check(!fm.fileExists(atPath: backups.appendingPathComponent("Empty/.partial").path) && ((try? fm.contentsOfDirectory(atPath: backups.appendingPathComponent("Empty").path)) ?? []).isEmpty,
          "and nothing left behind")
    // five sparse files of 120 MB: 600 MB, more than a backup may hold
    let bigDir = user.appendingPathComponent("Documents/Big")
    try! fm.createDirectory(at: bigDir, withIntermediateDirectories: true)
    for i in 0..<5 {
        let u = bigDir.appendingPathComponent("w\(i).sav")
        fm.createFile(atPath: u.path, contents: nil)
        let h = try! FileHandle(forWritingTo: u); try! h.truncate(atOffset: 120 << 20); try! h.close()
    }
    let tooBig = GameSaveBackups.collect(roots: [GameSaveRoot(path: "users/tester/Documents/Big", isFile: false, source: .played)], drive: drive)
    check(tooBig.tooBig, "more than 512 MB of saves is too big for a backup")
    var message = ""
    do { _ = try GameSaveBackups.backUp(title: "Big", roots: [GameSaveRoot(path: "users/tester/Documents/Big", isFile: false, source: .played)], drive: drive, kind: .manual, into: backups) }
    catch { message = error.localizedDescription }
    check(message.contains("bigger than 512 MB"), "and says so", message)
    let hugeFile = bigDir.appendingPathComponent("huge.sav")
    fm.createFile(atPath: hugeFile.path, contents: nil)
    let hh = try! FileHandle(forWritingTo: hugeFile); try! hh.truncate(atOffset: 200 << 20); try! hh.close()
    for i in 0..<5 { try! fm.removeItem(at: bigDir.appendingPathComponent("w\(i).sav")) }
    let leftOut = GameSaveBackups.collect(roots: [GameSaveRoot(path: "users/tester/Documents/Big", isFile: false, source: .played)], drive: drive)
    check(leftOut.files.isEmpty && leftOut.leftOut == 1 && !leftOut.tooBig, "a single file over 128 MB is left out and counted")
    try! fm.removeItem(at: bigDir)
}

// ------------------------------------------------------------------------------ rotation on disk
do {
    let title = "Rotation"
    let dir = GameSaveBackups.folder(for: title, in: backups)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<8 {
        let name = GameSaveRules.backupName(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 100), kind: .automatic, timeZone: utc)
        write(dir.appendingPathComponent(name), "auto \(i)")
    }
    write(dir.appendingPathComponent(GameSaveRules.backupName(date: Date(timeIntervalSince1970: 1_600_000_000), kind: .manual, timeZone: utc)), "mine")
    write(dir.appendingPathComponent(GameSaveRules.backupName(date: Date(timeIntervalSince1970: 1_600_000_100), kind: .beforeRestore, timeZone: utc)), "before")
    write(dir.appendingPathComponent("notes.txt"), "a file the player put here")
    let removed = GameSaveBackups.rotate(title: title, keep: 5, in: backups, timeZone: utc)
    let left = GameSaveBackups.list(title: title, in: backups, timeZone: utc)
    check(removed == 3 && left.filter { $0.kind == .automatic }.count == 5, "rotation removes the 3 oldest automatic backups", "\(removed)")
    check(left.contains { $0.kind == .manual } && left.contains { $0.kind == .beforeRestore } && fm.fileExists(atPath: dir.appendingPathComponent("notes.txt").path),
          "and nothing else: not the manual one, not the copy before a restore, not the player's file")
    check(left.first!.date > left.last!.date, "the list is newest first")
}

// ------------------------------------------------------------------------------ the job when a game closes
do {
    GameSaveStore.fileURL = scratch.appendingPathComponent("game-saves.json")
    GameSaveBackups.log = { _ in }
    let key = "c:\\program files\\foo\\foo.exe"
    check(GameSaveStore.record(key) == GameSaveRecord(), "a game with no record has the defaults: automatic off, keep 5")
    GameSaveStore.update(key) { $0.automatic = true }
    var logged: [String] = []
    GameSaveBackups.log = { logged.append($0) }

    // a fresh prefix for this scenario
    let drive2 = scratch.appendingPathComponent("drive2_c")
    let user2 = drive2.appendingPathComponent("users/tester")
    write(user2.appendingPathComponent("Documents/My Games/Bar/Saves/a.sav"), "first", modified: Date())
    write(user2.appendingPathComponent("AppData/Local/Temp/t.tmp"), "junk", modified: Date())
    let folder2 = scratch.appendingPathComponent("Backups2")
    let started = Date(timeIntervalSinceNow: -600)
    let first = GameSaveWork.backUpAfterSession(key: key, title: "Bar", started: started, drive: drive2, install: nil, cloud: [], into: folder2)
    check(first.contains("automatic backup of 1 files"), "after a session that saved: an automatic backup", first)
    check(GameSaveBackups.list(title: "Bar", in: folder2).count == 1 && GameSaveBackups.list(title: "Bar", in: folder2)[0].kind == .automatic, "it is in the folder as Automatic")
    check(GameSaveStore.record(key).roots.map(\.path) == ["users/tester/Documents/My Games/Bar"] && GameSaveStore.record(key).signature != nil, "the roots and the fingerprint are remembered")

    let second = GameSaveWork.backUpAfterSession(key: key, title: "Bar", started: Date(), drive: drive2, install: nil, cloud: [], into: folder2)
    check(second.contains("have not changed") && GameSaveBackups.list(title: "Bar", in: folder2).count == 1, "a session in which nothing changed makes no new backup", second)

    write(user2.appendingPathComponent("Documents/My Games/Bar/Saves/a.sav"), "second, longer", modified: Date(timeIntervalSinceNow: 5))
    let third = GameSaveWork.backUpAfterSession(key: key, title: "Bar", started: Date(timeIntervalSinceNow: -60), drive: drive2, install: nil, cloud: [], into: folder2)
    check(third.contains("automatic backup of 1 files") && GameSaveBackups.list(title: "Bar", in: folder2).count == 2, "changed saves make a second backup", third)

    // the roots learned stay when a later session changes nothing, so the saves are still backed up when they change
    GameSaveStore.update(key) { $0.signature = nil }
    let none = GameSaveWork.backUpAfterSession(key: key, title: "Bar", started: Date(timeIntervalSinceNow: 3600), drive: drive2, install: nil, cloud: [], into: folder2)
    check(none.contains("automatic backup") || none.contains("have not changed"), "known roots are backed up even when the session itself saw no change", none)

    // a game nothing is known about
    let nothing = GameSaveWork.backUpAfterSession(key: "c:\\unknown.exe", title: "Nothing", started: Date(timeIntervalSinceNow: 3600), drive: drive2, install: nil, cloud: [], into: folder2)
    check(nothing.contains("nothing backed up") && GameSaveBackups.list(title: "Nothing", in: folder2).isEmpty, "no changes and no roots: nothing is made", nothing)
    check(logged.allSatisfy { !$0.contains("tester") }, "the log lines never name the Windows user", logged.joined(separator: " | "))

    // the store is a file: a second load sees what the first wrote
    let text = (try? String(contentsOf: GameSaveStore.fileURL, encoding: .utf8)) ?? ""
    check(text.contains("\"automatic\":true") || text.contains("\"automatic\" : true"), "the record is written to its file", String(text.prefix(200)))
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    GameSaveStore.rememberSession(key, start: t, end: t.addingTimeInterval(120))
    check(GameSaveStore.lastSession(key)?.start == t && GameSaveStore.lastSession(key)?.end == t.addingTimeInterval(120), "the last session's times are remembered")
}

// ------------------------------------------------------------------------------ a scan stops at its limit, a backup at its file count
do {
    let drive3 = scratch.appendingPathComponent("drive3_c")
    let many = drive3.appendingPathComponent("users/tester/Documents/Many")
    try! fm.createDirectory(at: many, withIntermediateDirectories: true)
    for i in 0..<1500 { fm.createFile(atPath: many.appendingPathComponent("f\(i).sav").path, contents: Data([1])) }
    let scan = GameSaveBackups.changedFiles(since: Date(timeIntervalSinceNow: -3600), drive: drive3, users: ["tester"], install: nil, limit: 1000)
    check(scan.truncated && scan.entriesSeen == 1001 && scan.files.count == 999, "a folder with more files than the limit is searched up to the limit and says so",
          "seen \(scan.entriesSeen), found \(scan.files.count), truncated \(scan.truncated)")
    let whole = GameSaveBackups.changedFiles(since: Date(timeIntervalSinceNow: -3600), drive: drive3, users: ["tester"], install: nil)
    check(!whole.truncated && whole.files.count == 1500, "and the real limit (\(GameSaveRules.maxScanEntries)) does not cut 1500 files")
    var lines: [String] = []
    GameSaveBackups.log = { lines.append($0) }
    GameSaveStore.fileURL = scratch.appendingPathComponent("game-saves-3.json")
    let r = GameSaveWork.backUpAfterSession(key: "c:\\many.exe", title: "Many", started: Date(timeIntervalSinceNow: -3600), drive: drive3, install: nil, cloud: [],
                                            into: scratch.appendingPathComponent("Backups3"), scanLimit: 1000, maxFiles: 1200)
    check(lines.contains { $0.contains("looked at the first ones only") }, "the job's log says the scan stopped", lines.joined(separator: " | "))
    check(r.contains("automatic backup failed") && r.contains("more than BCD backs up on its own"), "a game with more save files than a backup may hold is not backed up, and the log says why", r)
    check(GameSaveBackups.list(title: "Many", in: scratch.appendingPathComponent("Backups3")).isEmpty
          && ((try? fm.contentsOfDirectory(atPath: scratch.appendingPathComponent("Backups3/Many").path)) ?? []).isEmpty, "and no half-made backup is left")
    check(GameSaveRules.maxBackupFiles <= 0xFFFE, "a backup never holds more entries than a zip can count")
}

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
