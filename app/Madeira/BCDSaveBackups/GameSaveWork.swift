// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Save backups per game (round 603), the work that needs no engine type: what BCD remembers about each game's saves and the
// background job that runs when a game closes (the hook, the Steam and library lookups are GameSaveAuto.swift). Foundation only,
// so tests/host/check-game-saves.py compiles it on the Mac with the rules and the file side and runs it.
//
// What is remembered, per game (by its program's Windows path), in Application Support/game-saves.json: the save roots found,
// whether to back up when the game closes (off unless the player turns it on), how many automatic backups to keep, and a
// fingerprint of the files at the last backup (so a game that saved nothing new is not backed up again). Every game also
// keeps the start and end of its last session in UserDefaults, which is all "Find where it saves" needs: the files that
// changed between the two. Nothing is scanned while a game runs, and when the switch is off nothing is scanned at all.

/// What BCD keeps about one game's saves.
struct GameSaveRecord: Codable, Equatable {
    var roots: [GameSaveRoot] = []
    var automatic = false
    var keep = GameSaveRules.keepDefault
    var signature: String?
    var lastBackup: Date?
}

enum GameSaveStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: GameSaveRecord]?
    /// Tests point this at a scratch file.
    nonisolated(unsafe) static var fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("game-saves.json")
    }()

    private static func load() -> [String: GameSaveRecord] {
        if let cache { return cache }
        let loaded = (try? JSONDecoder().decode([String: GameSaveRecord].self, from: Data(contentsOf: fileURL))) ?? [:]
        cache = loaded
        return loaded
    }

    static func record(_ key: String) -> GameSaveRecord {
        lock.lock(); defer { lock.unlock() }
        return load()[key] ?? GameSaveRecord()
    }

    static func update(_ key: String, _ edit: (inout GameSaveRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var record = all[key] ?? GameSaveRecord()
        edit(&record)
        all[key] = record == GameSaveRecord() ? nil : record
        cache = all
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// The game's last session, from its start to its end.
    static func lastSession(_ key: String) -> (start: Date, end: Date)? {
        guard let pair = (UserDefaults.standard.dictionary(forKey: "bcd.saves.lastSession") as? [String: [Double]])?[key], pair.count == 2 else { return nil }
        return (Date(timeIntervalSince1970: pair[0]), Date(timeIntervalSince1970: pair[1]))
    }

    static func rememberSession(_ key: String, start: Date, end: Date) {
        var all = (UserDefaults.standard.dictionary(forKey: "bcd.saves.lastSession") as? [String: [Double]]) ?? [:]
        all[key] = [start.timeIntervalSince1970, end.timeIntervalSince1970]
        UserDefaults.standard.set(all, forKey: "bcd.saves.lastSession")
    }
}

enum GameSaveWork {
    /// The job behind GameSaveAuto.sessionEnded, and what a test runs: looks for the session's changes, and writes the backup when the
    /// saves are new. Returns a line for the log.
    @discardableResult
    static func backUpAfterSession(key: String, title: String, started: Date, drive: URL, install: String?, cloud: [GameSaveRoot],
                                   into root: URL = GameSaveBackups.folder, scanLimit: Int = GameSaveRules.maxScanEntries,
                                   maxFiles: Int = GameSaveRules.maxBackupFiles) -> String {
        let users = GameSaveBackups.users(drive: drive)
        let scan = GameSaveBackups.changedFiles(since: started.addingTimeInterval(-2), drive: drive, users: users, install: install, limit: scanLimit)
        if scan.truncated { GameSaveBackups.log("[saves] \(title): the game's folders hold more than \(scanLimit) entries; BCD looked at the first ones only") }
        let learned = GameSaveRules.roots(changed: scan.files, users: users, install: install, source: .played)
        var record = GameSaveStore.record(key)
        let roots = GameSaveRules.merge(record.roots, GameSaveRules.merge(learned, cloud))
        if roots != record.roots { GameSaveStore.update(key) { $0.roots = roots } }
        func say(_ text: String) -> String {
            let line = "[saves] \(title): \(text)"
            GameSaveBackups.log(line)
            return line
        }
        guard !roots.isEmpty else { return say("no save files changed in this session and none are known; nothing backed up") }
        let files = GameSaveBackups.collect(roots: roots, drive: drive, maxFiles: maxFiles)
        let signature = GameSaveRules.signature(files.files)
        record = GameSaveStore.record(key)
        if signature == record.signature, !files.files.isEmpty { return say("the saves have not changed since the last backup") }
        do {
            let made = try GameSaveBackups.backUp(title: title, roots: roots, drive: drive, kind: .automatic, into: root, maxFiles: maxFiles)
            GameSaveStore.update(key) { $0.signature = signature; $0.lastBackup = Date() }
            GameSaveBackups.rotate(title: title, keep: record.keep, in: root)
            return say("automatic backup of \(made.files) files (\(made.bytes) bytes)")
        } catch {
            return say("automatic backup failed: \(error.localizedDescription)")
        }
    }
}
