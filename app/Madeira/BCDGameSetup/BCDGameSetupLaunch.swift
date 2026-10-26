// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604), what a start does: the one hook, LibraryEntry.applyEnvironment, calls BCDGameSetup.prepare on the launch
// worker before the JIT pool is taken and before the wineserver exists. It reads the game's own file (GameProfiles.swift) and
//   * sets the program's Windows version (win.version) in the registry, for the programs the start can run,
//   * sets the Wine desktop's text size, colours and wallpaper (desktop.dpi, desktop.theme, desktop.wallpaper) when the start is a
//     Wine desktop (the library's Desktop, or a game started "In a Wine desktop"),
//   * runs the game's fixes (fix.N lines).
// These registry values are managed: they are put back when the line goes or another kind of start follows (BCDRegistryEdit).
// A game whose file has none of these lines, in a prefix BCD has set nothing in, costs one file-exists check here and nothing else.
// Everything is logged as [game-setup]; a problem is logged and the start goes on.

enum BCDGameSetup {
    static var prefix: URL { LibraryModel.documents.appendingPathComponent("wine", isDirectory: true) }
    static var drive: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }

    /// Documents/Fix Backups/<game>, where the first original of a changed file and the newest of what a delete took are kept.
    static func fixBackups(title: String) -> URL {
        let name = String(title.map { "/\\:*?\"<>|\0".contains($0) ? "-" : $0 }.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return LibraryModel.documents.appendingPathComponent("Fix Backups", isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "Game" : name, isDirectory: true)
    }

    /// The game's own folder, relative to drive_c with "/": a Steam game's `relativePath` is its install folder; for another game it
    /// is the folder its program is in (never the root, Windows' folders or a bare program-files folder).
    static func installFolder(_ entry: LibraryEntry) -> String? {
        let parts = entry.relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        var folder = parts
        if entry.steamAppID == nil {
            guard parts.count >= 2 else { return nil }
            folder.removeLast()
        }
        let first = folder[0].lowercased()
        if first == "windows" || first == "users" || first == "programdata" || first == "external" { return nil }
        if folder.count == 1 && (first == "program files" || first == "program files (x86)") { return nil }
        return folder.joined(separator: "/")
    }

    /// The programs a start of this game can run, by file name: the program it starts and, for a game BCD Dock starts through Steam,
    /// the programs in its folder (down to three folders deep, at most 40).
    static func programNames(_ entry: LibraryEntry) -> [String] {
        var names: [String] = []
        func add(_ name: String) {
            if BCDWindowsVersion.isProgramName(name), !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        let launch = entry.launchRelativePath.replacingOccurrences(of: "\\", with: "/")
        if launch.lowercased().hasSuffix(".exe") { add((launch as NSString).lastPathComponent) }
        if entry.steamAppID != nil && !entry.startsSteamGameDirectly, let folder = installFolder(entry) {
            let base = BCDFixPaths.onDisk(base: drive, parts: folder.split(separator: "/").map(String.init))
            var seen = 0
            if let walk = FileManager.default.enumerator(atPath: base.path) {
                while let rel = walk.nextObject() as? String, names.count < 40, seen < 4000 {
                    seen += 1
                    if rel.split(separator: "/").count > 4 { walk.skipDescendants(); continue }
                    if rel.lowercased().hasSuffix(".exe") { add((rel as NSString).lastPathComponent) }
                }
            }
        }
        return names
    }

    /// The registry values the game's file asks to be set for this start.
    static func managedEdits(_ entry: LibraryEntry, values: [String: String]) -> [BCDRegistryEdit.Edit] {
        var edits: [BCDRegistryEdit.Edit] = []
        if let id = values[BCDWindowsVersion.key], let wine = BCDWindowsVersion.registryValue(id, is64Bit: entry.bits == 64) {
            for program in programNames(entry) {
                edits.append(BCDRegistryEdit.Edit(file: "user.reg", key: BCDWindowsVersion.appKey(program: program), name: "Version",
                                                  raw: BCDRegValue.string(wine).regText))
            }
        }
        if entry.desktop == true || entry.runsInDesktop {
            if let dpi = values[BCDWineDesktop.dpiKey], BCDWineDesktop.isDPI(dpi), let n = UInt32(dpi), n != 96 {
                edits.append(BCDRegistryEdit.Edit(file: "user.reg", key: "Control Panel\\Desktop", name: "LogPixels", raw: BCDRegValue.dword(n).regText))
            }
            if values[BCDWineDesktop.themeKey] == "dark" {
                for color in BCDWineDesktop.darkColors {
                    edits.append(BCDRegistryEdit.Edit(file: "user.reg", key: "Control Panel\\Colors", name: color.name, raw: BCDRegValue.string(color.rgb).regText))
                }
            }
            if let paper = values[BCDWineDesktop.wallpaperKey], BCDWineDesktop.isWallpaperPath(paper) {
                edits.append(BCDRegistryEdit.Edit(file: "user.reg", key: "Control Panel\\Desktop", name: "Wallpaper", raw: BCDRegValue.string(paper).regText))
            }
        }
        return edits
    }

    /// For the launch worker. Never throws and never stops a start.
    static func prepare(_ entry: LibraryEntry) {
        let fm = FileManager.default
        let profile = GameProfile(windowsPath: entry.windowsPath)
        let values = profile.values
        let owned = fm.fileExists(atPath: prefix.appendingPathComponent(BCDRegistryEdit.stateName).path)
        let wantsFixes = values.keys.contains { $0.hasPrefix(BCDGameFixes.onPrefix) }
        let wantsRegistry = values[BCDWindowsVersion.key] != nil || values.keys.contains { $0.hasPrefix("desktop.") }
        let wantsStart = values.keys.contains { $0.hasPrefix("start.") || $0.hasPrefix(BCDStartPlan.rulePrefix) }
        let saves = BCDSaveRedirect.folder(documents: LibraryModel.documents)
        let movedSaves = fm.fileExists(atPath: saves.appendingPathComponent(BCDSaveRedirect.stateName).path)
        guard owned || wantsFixes || wantsRegistry || movedSaves || wantsStart else { return }

        let managed = managedEdits(entry, values: values)
        var permanent: [BCDRegistryEdit.Edit] = []
        var lines: [String] = []

        // Save folders the game keeps in Files › BCD › Game Saves: a prefix that lost its link (it was reset) gets it again.
        if movedSaves { lines += BCDSaveRedirect.repair(game: entry.windowsPath.lowercased(), drive: drive, folder: saves) }

        if wantsFixes {
            let listed = BCDGameFixes.list(values)
            for problem in listed.problems { lines.append("[game-fix] \(problem)") }
            let users = BCDFixPaths.users(drive: drive)
            let context = BCDFixPaths.Context(users: users + ["Public"], install: installFolder(entry))
            var setting = BCDGameFixRunner.Setting(drive: drive, context: context, backups: fixBackups(title: entry.title), extractMember: BCDGameFixRedist.extractMember)
            setting.now = Date()
            let outcome = BCDGameFixRunner.run(Array(listed.fixes.prefix(BCDGameFixes.maxFixes)), setting)
            lines += outcome.lines
            permanent = outcome.registry
            if outcome.done + outcome.failed > 0 || !listed.problems.isEmpty {
                lines.append("[game-fix] \(entry.title): \(outcome.done) done, \(outcome.unchanged) already in place, \(outcome.failed) skipped or failed")
            }
        }

        if !managed.isEmpty || !permanent.isEmpty || owned {
            let result = BCDRegistryEdit.apply(managed: managed, permanent: permanent, prefix: prefix)
            if result.changed > 0 || result.retracted > 0 || !result.problems.isEmpty {
                lines.append("[game-setup] registry: \(result.changed) set, \(result.retracted) put back" + (result.written.isEmpty ? "" : " (" + result.written.joined(separator: ", ") + ")"))
            }
            for problem in result.problems { lines.append("[game-setup] registry: \(problem)") }
        }
        lines += wrapStart(entry, values: values)   // a delay, a second program or window rules: the start goes through a script (BCDGameStartLaunch.swift)
        for line in lines { LogStore.shared.log(line) }
    }
}
