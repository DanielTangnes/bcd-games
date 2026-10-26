// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The game page's save backups, engine side (BCDGameSaves.swift has the section's words and rules; GameSaveRules.swift,
// GameSaveBackups.swift and GameSaveAuto.swift do the work). Engine-bound like BCDGamePageLive.swift, so the preview build leaves
// it out (it lives in a folder the preview build does not read).
//
// The section is an ordinary group of settings: its rows are built from the game's record and the backup folder's listing when
// Options is open (no scanning, no file is read but the folder's names and sizes), and every action runs on a background queue and
// says what it did on its own row. A restore is asked about by the page before this code runs, and makes a "Before restore"
// backup of the current saves first; if that cannot be made, nothing is replaced.

@MainActor final class BCDSaveBackupsNotes {
    static let shared = BCDSaveBackupsNotes()
    /// What each action last said, and which are running, by game id and setting id.
    var notes: [String: [String: String]] = [:]
    var busy: [String: Set<String>] = [:]
}

extension BCDGamePageLive {
    /// The section for an installed game that has its own program (not the Wine desktop).
    func saveBackupsGroup(_ game: BCDGame, _ entry: LibraryEntry) -> BCDGameSettingGroup {
        let key = GameSaveAuto.key(entry)
        let record = GameSaveStore.record(key)
        let install = GameSaveAuto.installFolder(entry)
        let ui = BCDSaveBackupsNotes.shared
        var state = BCDSaveBackupsState()
        state.places = record.roots.map { root in
            GameSaveRules.display(root, install: install) + (root.source == .steamCloud ? " (Steam Cloud's list)" : "")
        }
        state.automatic = record.automatic
        state.keep = record.keep
        state.folder = "Save Backups › " + GameSaveRules.safeFolderName(entry.title)
        state.sessionKnown = GameSaveStore.lastSession(key) != nil
        state.notes = ui.notes[game.id] ?? [:]
        state.busy = ui.busy[game.id] ?? []
        let all = GameSaveBackups.list(title: entry.title)
        state.backups = all.prefix(BCDGameSaves.listLimit).map {
            BCDSaveBackupItem(id: $0.name, date: $0.date, kind: $0.kind.rawValue, bytes: $0.bytes)
        }
        state.older = max(0, all.count - state.backups.count)
        return BCDGameSaves.group(state)
    }

    /// The section's settings: true when `setting` was one of them.
    func saveBackupsSet(_ setting: String, to value: String, for game: BCDGame) -> Bool {
        guard setting.hasPrefix("savebackups."), let entry = saveBackupsEntry(game) else { return false }
        GameSaveBackups.log = { LogStore.shared.log($0) }
        let key = GameSaveAuto.key(entry)
        switch setting {
        case BCDGameSaves.auto:
            let on = value == "1"
            GameSaveStore.update(key) { $0.automatic = on }
            say(game, setting, on ? "On. After a session in which the game changed its saves, BCD makes an Automatic backup." : "Off.")
        case BCDGameSaves.now:
            run(game, setting, working: "Packing the saves…") { [self] in try await manualBackup(entry) }
        case BCDGameSaves.find:
            run(game, setting, working: "Looking at the files the game changed…") { [self] in try await findSaves(entry) }
        case BCDGameSaves.forget:
            GameSaveStore.update(key) { $0.roots = []; $0.signature = nil }
            say(game, setting, "Forgotten. BCD looks again after the game's next session.")
        case let id where BCDGameSaves.backupName(ofRestore: id) != nil:
            let name = BCDGameSaves.backupName(ofRestore: id) ?? ""
            run(game, setting, working: "Putting the saves back…") { [self] in try await restoreBackup(entry, name: name) }
        default:
            break
        }
        return true
    }

    /// The library entry of an installed game with a program of its own.
    private func saveBackupsEntry(_ game: BCDGame) -> LibraryEntry? {
        guard game.state.isInstalled, let entry = entry(for: game), entry.desktop != true else { return nil }
        return entry
    }

    // MARK: Say and run

    private func say(_ game: BCDGame, _ id: String, _ text: String?) {
        let ui = BCDSaveBackupsNotes.shared
        var notes = ui.notes[game.id] ?? [:]
        notes[id] = text
        ui.notes[game.id] = notes
        onChange?()
    }

    /// Runs `work` off the main actor, shows `working` on the row meanwhile and the outcome afterwards. A second press while it
    /// runs does nothing.
    private func run(_ game: BCDGame, _ id: String, working: String, _ work: @escaping () async throws -> String) {
        let ui = BCDSaveBackupsNotes.shared
        guard !(ui.busy[game.id]?.contains(id) ?? false) else { return }
        ui.busy[game.id, default: []].insert(id)
        say(game, id, working)
        Task { [weak self] in
            let text: String
            do { text = try await work() } catch { text = error.localizedDescription }
            ui.busy[game.id]?.remove(id)
            self?.say(game, id, text)
        }
    }

    // MARK: The actions

    private func context(_ entry: LibraryEntry) -> (drive: URL, install: String?, cloud: [GameSaveRoot]) {
        let drive = LibraryModel.drive
        let install = GameSaveAuto.installFolder(entry)
        let cloud = entry.steamAppID.map { GameSaveAuto.steamCloudRoots(appID: $0, drive: drive, install: install) } ?? []
        return (drive, install, cloud)
    }

    private func manualBackup(_ entry: LibraryEntry) async throws -> String {
        let key = GameSaveAuto.key(entry), title = entry.title
        let (drive, _, cloud) = context(entry)
        let record = GameSaveStore.record(key)
        let roots = GameSaveRules.merge(record.roots, cloud)
        guard !roots.isEmpty else {
            return "BCD does not know where this game keeps its saves yet. Play it, save in it and close it, then choose Find where it saves."
        }
        let made = try await Task.detached(priority: .userInitiated) {
            try GameSaveBackups.backUp(title: title, roots: roots, drive: drive, kind: .manual)
        }.value
        GameSaveStore.update(key) { $0.roots = roots }
        return "Backed up \(made.files) file\(made.files == 1 ? "" : "s") (\(BCDFormat.bytes(made.bytes)))."
    }

    private func findSaves(_ entry: LibraryEntry) async throws -> String {
        let key = GameSaveAuto.key(entry)
        guard let session = GameSaveStore.lastSession(key) else {
            return "BCD has not seen this game run yet. Play it, save in it and close it, then try again."
        }
        let (drive, install, cloud) = context(entry)
        let found = await Task.detached(priority: .userInitiated) { () -> [GameSaveRoot] in
            let users = GameSaveBackups.users(drive: drive)
            let scan = GameSaveBackups.changedFiles(since: session.start.addingTimeInterval(-2), drive: drive, users: users, install: install)
            // Only what changed while it ran: files touched after the session ended belong to something else.
            let during = scan.files.filter { $0.modified <= session.end.timeIntervalSince1970 + 30 }
            return GameSaveRules.roots(changed: during, users: users, install: install, source: .played)
        }.value
        let record = GameSaveStore.record(key)
        let roots = GameSaveRules.merge(record.roots, GameSaveRules.merge(found, cloud))
        GameSaveStore.update(key) { $0.roots = roots }
        let added = roots.count - record.roots.count
        if roots.isEmpty {
            return "BCD found no files this game changed in its last session. Save in the game before you close it, then try again."
        }
        return "\(roots.count) place\(roots.count == 1 ? "" : "s") known" + (added > 0 ? ", \(added) new." : ".")
    }

    private func restoreBackup(_ entry: LibraryEntry, name: String) async throws -> String {
        let key = GameSaveAuto.key(entry), title = entry.title
        let drive = LibraryModel.drive
        guard let backup = GameSaveBackups.list(title: title).first(where: { $0.name == name }) else {
            return "That backup is not in the folder any more."
        }
        let record = GameSaveStore.record(key)
        let outcome = try await Task.detached(priority: .userInitiated) { () -> (written: Int, before: String?) in
            // What is there now is kept first. Nothing is replaced if that copy cannot be made.
            let roots = GameSaveRules.merge(record.roots, GameSaveBackups.roots(ofBackup: backup.url))
            var before: String?
            if !GameSaveBackups.collect(roots: roots, drive: drive).files.isEmpty {
                before = try GameSaveBackups.backUp(title: title, roots: roots, drive: drive, kind: .beforeRestore).url.lastPathComponent
            }
            let restored = try GameSaveBackups.restore(backup.url, drive: drive)
            return (restored.written, before)
        }.value
        GameSaveStore.update(key) { $0.signature = nil }
        return "Put back \(outcome.written) file\(outcome.written == 1 ? "" : "s")."
            + (outcome.before.map { " What was there is kept in \"\($0)\"." } ?? "")
    }
}
