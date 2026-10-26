// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Save backups per game (round 603), the engine side of the automatic backup: the hook LibraryModel.finish() calls when a game
// closes, the game's own folder, and the places Steam Cloud's list points to. What is remembered and the job itself are
// GameSaveWork.swift; the rules GameSaveRules.swift; the files GameSaveBackups.swift.
//
// When a game closes with the switch on, a background task looks for the files the session changed, adds their roots to the
// game's, and, if the saves are not the ones already backed up, writes an Automatic backup and removes the automatic ones
// beyond the number kept. A session that ended in a Windows error is not backed up: the saves it left may be half written,
// and the copies before it must stay. Log tag: [saves] (counts and the game's title; paths without the Windows user's name).

enum GameSaveAuto {
    /// The key a game's record and session are kept under.
    static func key(_ entry: LibraryEntry) -> String { entry.windowsPath.lowercased() }

    /// The game's own folder from drive_c, when it has one of its own: a Steam game's folder under steamapps/common, else the
    /// folder its program is in (not the drive's root and not one of Windows' own folders).
    @MainActor static func installFolder(_ entry: LibraryEntry) -> String? {
        if let id = entry.steamAppID, let game = SteamGamesModel.shared.games.first(where: { $0.id == id }) {
            let library = game.library.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            return (library + "/common/" + game.installDir).replacingOccurrences(of: "\\", with: "/")
        }
        var parts = (GameSaveRules.parts(entry.relativePath) ?? [])
        guard parts.count >= 2 else { return nil }
        parts.removeLast()
        let first = parts[0].lowercased()
        if first == "windows" || first == "users" || first == "programdata" { return nil }
        if parts.count == 1 && (first == "program files" || first == "program files (x86)") { return nil }
        return parts.joined(separator: "/")
    }

    /// The folders Steam Cloud's comparison of a game lists (the comparison BCD made this run), as roots.
    @MainActor static func steamCloudRoots(appID: Int, drive: URL, install: String?) -> [GameSaveRoot] {
        guard let state = SteamOwnedLibrary.shared.cloud[appID], let user = SteamCloudPaths.userFolder(drive: drive) else { return [] }
        let home = "users/" + user.url.lastPathComponent
        var out: [GameSaveRoot] = []
        for entry in state.audit.entries {
            let (root, rest) = SteamCloudPaths.split(entry.path)
            guard let root else { continue }   // Steam's own remote folder: Steam Cloud syncs it
            var base: String?
            switch SteamCloudPaths.canonical(root: root) {
            case "GameInstall": base = install
            case "WinMyDocuments": base = home + "/Documents"
            case "WinAppDataLocal": base = home + "/AppData/Local"
            case "WinAppDataLocalLow": base = home + "/AppData/LocalLow"
            case "WinAppDataRoaming": base = home + "/AppData/Roaming"
            case "WinSavedGames": base = home + "/Saved Games"
            default: base = nil
            }
            guard let base, let parts = GameSaveRules.parts(rest.replacingOccurrences(of: "\\", with: "/")) else { continue }
            if parts.count == 1 {
                out.append(GameSaveRoot(path: base + "/" + parts[0], isFile: true, source: .steamCloud))
            } else {
                out.append(GameSaveRoot(path: base + "/" + parts.dropLast().joined(separator: "/"), isFile: false, source: .steamCloud))
            }
        }
        return GameSaveRules.merge([], out)
    }

    // MARK: When a game closes

    /// One line in LibraryModel.finish(): remembers the session's start and end, and, when the player turned the backup on for
    /// this game, starts it on a background queue (the game's end must be on the main thread, as finish() is). A session that
    /// ended in a Windows error is not backed up: the saves it left may be half written and the copies before it must stay.
    static func sessionEnded(_ entry: LibraryEntry?, started: Date) {
        guard let entry else { return }
        let key = key(entry)
        GameSaveStore.rememberSession(key, start: started, end: Date())
        guard GameSaveStore.record(key).automatic else { return }
        var status: UInt32 = 0
        let crashed = wine_crash_exit_status(&status) != 0
        MainActor.assumeIsolated { startAutomatic(entry, started: started, crashed: crashed) }
    }

    @MainActor private static func startAutomatic(_ entry: LibraryEntry, started: Date, crashed: Bool) {
        GameSaveBackups.log = { LogStore.shared.log($0) }
        let key = key(entry), title = entry.title
        guard !crashed else {
            LogStore.shared.log("[saves] \(title): the game ended with an error; no automatic backup (the saves it left may be half written)")
            return
        }
        let drive = LibraryModel.drive, install = installFolder(entry)
        let cloud = entry.steamAppID.map { steamCloudRoots(appID: $0, drive: drive, install: install) } ?? []
        Task.detached(priority: .utility) {
            _ = GameSaveWork.backUpAfterSession(key: key, title: title, started: started, drive: drive, install: install, cloud: cloud)
        }
    }
}
