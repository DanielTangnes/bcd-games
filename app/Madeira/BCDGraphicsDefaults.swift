// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The graphics defaults BCD picks for a game from its own folder (round 602, 2026-10-25). One hook in LibraryEntry.applyEnvironment
// (Library.swift) calls this file; the scan itself is BCDGraphicsScan.swift.
//
// 64-bit Direct3D 9. A 64-bit program loads C:\windows\sysx64\d3d9.dll. Wine's own draws through wined3d's OpenGL backend and a phone has
// no OpenGL, so Direct3DCreate9 fails ("wined3d_adapter_gl_init Failed to get a GL context", "d3d9_init FAILED") and the game blames its
// resolution or crashes on the empty result (Darksiders II, PICO PARK, Counter-Strike: Source, MudRunner, Indivisible...). Since build 595
// env.MADEIRA_D3D9_X64 = dxmt links DXMT's Direct3D 9 (d3d9-dxmt.dll) instead, but only a game's own line asked for it. From build 602 the
// answer is "dxmt" by default for a game whose folder shows a 64-bit Direct3D 9 program and nothing of Direct3D 11, DXGI or Direct3D 12
// (BCDGraphicsScan.decide). Everything else is exactly what it was: a game that falls back to Direct3D 11 after the failed probe (Cult of
// the Lamb, Graveyard Keeper, Moonlighter, Counter-Strike 2, Trails in the Sky, Warriors Orochi 3), the Rockstar and Chromium launchers, the
// games that play today, and any game the scan cannot be sure about.
//
// The game's own word always wins: env.MADEIRA_D3D9_X64 = wined3d (or dxmt) in bcd.cfg, in the game's lines or in its profile file is
// never replaced, and env.BCD_D3D9_X64_AUTO = 0 in bcd.cfg turns the default off for every game. The decision is logged:
//   [d3d9-x64] default=dxmt because <reason>
//   [d3d9-x64] default unchanged (Wine's d3d9.dll): <reason>
enum BCDGraphicsDefaults {
    /// The key the bridge reads (WineProcessBridge.m links d3d9-dxmt.dll when its value is "dxmt").
    static let d3d9X64Key = "MADEIRA_D3D9_X64"
    /// bcd.cfg's master switch: `env.BCD_D3D9_X64_AUTO = 0` keeps Wine's d3d9.dll for every game that does not ask otherwise.
    static let d3d9X64AutoKey = "BCD_D3D9_X64_AUTO"
    /// Set by this file for the session in progress, so a later session never inherits the value.
    private static var setHere = false

    /// What the bridge will find for the game: nil when a value is already set by the game's own word, otherwise the default is decided now.
    /// Returns the value this call exported ("dxmt") or nil.
    @discardableResult
    static func applyD3D9X64(for entry: LibraryEntry) -> String? {
        if setHere { unsetenv(d3d9X64Key); setHere = false }
        guard MadeiraConfig.flag(d3d9X64AutoKey) else {
            LogStore.shared.log("[d3d9-x64] default unchanged (Wine's d3d9.dll): env.\(d3d9X64AutoKey) = 0 in bcd.cfg")
            return nil
        }
        // The game's own word: bcd.cfg, the entry's lines, the game's profile file (MADEIRA_CFG_GAME, written by applyGame just before),
        // or a variable the process already has.
        let key = "env." + d3d9X64Key
        let own = MadeiraConfig.get(key) ?? MadeiraConfig.parse(entry.gameConfigText ?? "")[key] ?? MadeiraConfig.gameValue(key)
            ?? getenv(d3d9X64Key).map { String(cString: $0) }
        if let own {
            LogStore.shared.log("[d3d9-x64] default not applied: the game's own word is \(d3d9X64Key) = \(own)")
            return nil
        }
        // The library may already know the game as a Direct3D 11 or 12 one (its program's imports, read when it was added): nothing to scan.
        if let known = entry.graphicsAPI, known.contains("D3D11") || known.contains("D3D12") {
            LogStore.shared.log("[d3d9-x64] default unchanged (Wine's d3d9.dll): the library knows this game as \(known)")
            return nil
        }
        guard let root = folder(of: entry) else { return nil }
        // The answer of an earlier start, while the folder and the program it starts have not changed: no scan, no time added to the start.
        let signature = folderSignature(root, target: LibraryModel.drive.appendingPathComponent(entry.launchRelativePath))
        if let cached = cachedDecision(root, signature: signature) {
            if cached.dxmt {
                setenv(d3d9X64Key, "dxmt", 1)
                setHere = true
                LogStore.shared.log("[d3d9-x64] default=dxmt because \(cached.why) (\(root.lastPathComponent), remembered)")
                return "dxmt"
            }
            LogStore.shared.log("[d3d9-x64] default unchanged (Wine's d3d9.dll): \(cached.why) (\(root.lastPathComponent), remembered)")
            return nil
        }
        let started = Date()
        let result = BCDGraphicsScan.scan(root)
        let (dxmt, why) = BCDGraphicsScan.decide(result)
        let took = Int(Date().timeIntervalSince(started) * 1000)
        remember(root, signature: signature, dxmt: dxmt, why: why)
        if dxmt {
            setenv(d3d9X64Key, "dxmt", 1)
            setHere = true
            LogStore.shared.log("[d3d9-x64] default=dxmt because \(why) (\(root.lastPathComponent), \(result.bytesRead >> 20) MB read, \(took) ms)")
            return "dxmt"
        }
        LogStore.shared.log("[d3d9-x64] default unchanged (Wine's d3d9.dll): \(why) (\(root.lastPathComponent), \(took) ms)")
        return nil
    }

    // MARK: the remembered answers (lead, round 602: a scan may take up to its 4 s limit, so a game's later starts reuse its answer)

    /// UserDefaults key of the remembered answers: [folder path: "signature|1 or 0|reason"].
    static let cacheKey = "bcd.d3d9x64.decisions"
    /// At most this many games are remembered; when full, one other entry makes room.
    static let cacheLimit = 300

    /// What changes when the game is updated or files are added at its top level: the folder's and the started program's modification
    /// times and the program's size. A different signature means a new scan.
    static func folderSignature(_ root: URL, target: URL) -> String {
        func stamp(_ url: URL) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
            let t = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a[.size] as? NSNumber)?.int64Value ?? 0
            return "\(Int64(t))/\(s)"
        }
        return stamp(root) + "+" + stamp(target)
    }

    static func cachedDecision(_ root: URL, signature: String) -> (dxmt: Bool, why: String)? {
        guard let all = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String],
              let line = all[root.path] else { return nil }
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == signature, parts[1] == "1" || parts[1] == "0" else { return nil }
        return (parts[1] == "1", parts[2])
    }

    static func remember(_ root: URL, signature: String, dxmt: Bool, why: String) {
        var all = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        if all[root.path] == nil, all.count >= cacheLimit, let drop = all.keys.first { all.removeValue(forKey: drop) }
        all[root.path] = signature + "|" + (dxmt ? "1" : "0") + "|" + why.replacingOccurrences(of: "|", with: "/")
        UserDefaults.standard.set(all, forKey: cacheKey)
    }

    /// The folder tree of the game an entry starts, or nil (the Desktop entry, a batch file, a game not on disk) with nothing changed.
    static func folder(of entry: LibraryEntry) -> URL? {
        guard entry.desktop != true, !entry.isBatch, !entry.relativePath.isEmpty else { return nil }
        let drive = LibraryModel.drive
        func inside(_ url: URL) -> Bool { url.path.hasPrefix(drive.path + "/") }   // drive_c only: a game on another volume is left alone
        // Never a whole drive or a system folder: a program that sits in C:\ or C:\Program Files has no folder of its own to look at.
        let shared: Set<String> = ["program files", "program files (x86)", "windows", "users", "programdata", "steam", "steamapps", "common", "games", "external"]
        func usable(_ url: URL) -> Bool {
            url.path != drive.path && inside(url) && !shared.contains(url.lastPathComponent.lowercased())
                && FileManager.default.fileExists(atPath: url.path)
        }
        if entry.steamAppID != nil {
            // A Steam entry's relativePath is its install folder; "The game" starts a program inside it.
            let install = drive.appendingPathComponent(entry.relativePath).resolvingSymlinksInPath()
            return usable(install) ? install : nil
        }
        let target = drive.appendingPathComponent(entry.launchRelativePath).resolvingSymlinksInPath()
        guard inside(target), FileManager.default.fileExists(atPath: target.path) else { return nil }
        let root = BCDGraphicsScan.installationRoot(of: target, inside: inside, stopAt: { _ in false })
        return usable(root) ? root : nil
    }
}
