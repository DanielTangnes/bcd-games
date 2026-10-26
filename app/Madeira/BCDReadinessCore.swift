// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The launch readiness check (round 604, D6): before a player presses Play, the game page can say "this game wants X, which this device does
// not have yet", in one line, with where to get it. A game that stops at start with c0000135 ("a DLL was not found") says nothing that a
// player understands; the log of 1,426 sessions shows the usual few: MFC 2015-2022 (mfc140u.dll, mfc140.dll: five games), PhysX
// (physxloader.dll), OpenAL (openal32.dll), and a .NET program with no Wine Mono. The check reads what the game's own program files import
// (BCDGraphicsScan.inspect: the import tables, a few kilobytes of each) and compares it with what this device has. It changes nothing and
// blocks nothing: it is a note on the page. Plain values: tests/host/check-bcd-readiness.py compiles this file alone with BCDGraphicsScan.swift.

/// What one program file of the game imports.
struct BCDReadinessModule: Equatable {
    var file: String
    var is64: Bool
    var imports: Set<String>
}

/// What this device has for a game to find, as the live side reads it.
struct BCDReadinessProvided: Equatable {
    /// Microsoft's Visual C++ 2015-2022 x64 copy (Settings › Visual C++, or bundled): it carries mfc140.dll and mfc140u.dll.
    var vcRuntimeX64 = false
    /// Wine Mono (Settings › .NET Framework).
    var wineMono = false
    /// The Start menu's BCD Runtimes installers that have run (their markers in C:\ProgramData\BCD\Runtimes).
    var openAL = false
    var physX = false
    var xna = false
    var directX2010 = false
}

struct BCDReadinessFinding: Equatable, Identifiable {
    var id: String
    /// One sentence for the game's page.
    var text: String
    /// Whether BCD can supply it at all (false: nothing BCD offers fixes this).
    var fixable: Bool
}

enum BCDReadiness {
    /// The most the page shows: the first one or two, most useful first.
    static let maxShown = 2

    /// The 32-bit DLLs Microsoft's DirectX June 2010 redistributable has and BCD's 32-bit farm does not (ajan49's list, round 603).
    static let missing32DirectX: Set<String> = [
        "xapofx1_0.dll", "d3dcsx_42.dll", "d3dcsx_43.dll", "d3dx10.dll",
        "xactengine2_1.dll", "xactengine2_2.dll", "xactengine2_3.dll", "xactengine2_5.dll", "xactengine2_6.dll", "xactengine2_8.dll", "xactengine2_10.dll",
    ]

    /// BCD has no 64-bit XACT at all (a 64-bit program importing any xactengine finds none), and lacks the same few others.
    static func missing64DirectX(_ name: String) -> Bool {
        name.hasPrefix("xactengine") || ["xapofx1_0.dll", "d3dcsx_42.dll", "d3dcsx_43.dll", "d3dx10.dll"].contains(name)
    }

    static func isMFC(_ name: String) -> Bool {
        name.hasPrefix("mfc140") || name.hasPrefix("mfcm140")
    }

    /// The findings for a game: `modules` are the program files that were read, `files` every file name (lowercased) found in the game's
    /// folder tree (a DLL the game carries itself is found next to it, so it is not missing).
    static func evaluate(modules: [BCDReadinessModule], files: Set<String>, provided: BCDReadinessProvided) -> [BCDReadinessFinding] {
        var out: [BCDReadinessFinding] = []
        func add(_ id: String, _ text: String, fixable: Bool = true) {
            if !out.contains(where: { $0.id == id }) { out.append(BCDReadinessFinding(id: id, text: text, fixable: fixable)) }
        }
        for m in modules {
            for name in m.imports.sorted() {
                if isMFC(name) && !files.contains(name) {
                    if m.is64 {
                        // Microsoft's own copy has mfc140.dll and mfc140u.dll; the other MFC files (debug, language, mfcm) it does not.
                        if !provided.vcRuntimeX64 || !["mfc140.dll", "mfc140u.dll"].contains(name) {
                            add("mfc64", provided.vcRuntimeX64
                                ? "\(m.file) wants \(name), which Microsoft's Visual C++ runtime does not have. BCD cannot supply it."
                                : "\(m.file) wants \(name) (Microsoft's MFC). Download the Visual C++ runtime in Settings first.",
                                fixable: !provided.vcRuntimeX64)
                        }
                    } else {
                        add("mfc32", "\(m.file) is a 32-bit program that wants \(name) (Microsoft's MFC). BCD does not carry the 32-bit one yet.", fixable: false)
                    }
                }
                switch name {
                case "mscoree.dll" where !provided.wineMono:
                    add("mono", "\(m.file) is a .NET program. Download Wine Mono in Settings › .NET Framework first.")
                case "openal32.dll" where !provided.openAL && !files.contains(name):
                    add("openal", "\(m.file) wants OpenAL. Install it from the Start menu: BCD Runtimes › OpenAL.")
                case "physxloader.dll" where !provided.physX && !files.contains(name):
                    add("physx", "\(m.file) wants NVIDIA PhysX. Install it from the Start menu: BCD Runtimes › PhysX (legacy).")
                default:
                    break
                }
                if !provided.directX2010 && !files.contains(name) && (m.is64 ? missing64DirectX(name) : missing32DirectX.contains(name)) {
                    add("dx2010", "\(m.file) wants \(name), an older DirectX file. Install it from the Start menu: BCD Runtimes › DirectX June 2010.")
                }
            }
        }
        // XNA is a set of .NET assemblies a game carries a reference to: the game's folder names them.
        if !provided.xna && files.contains("microsoft.xna.framework.dll") && !files.contains("xnafx40_redist.msi") {
            add("xna", "This game uses Microsoft XNA. Install it from the Start menu: BCD Runtimes › XNA Framework 4.0.")
        }
        // Blocking findings (nothing BCD offers fixes them) come last: the fixable ones tell the player what to do.
        return out.filter(\.fixable) + out.filter { !$0.fixable }
    }

    /// The note for the page: nil when nothing is missing.
    static func note(_ findings: [BCDReadinessFinding]) -> String? {
        guard !findings.isEmpty else { return nil }
        let shown = findings.prefix(maxShown).map(\.text)
        let more = findings.count - shown.count
        return shown.joined(separator: " ") + (more > 0 ? " (\(more) more in the log.)" : "")
    }

    /// The line the log gets when the check ran.
    static func logLine(game: String, modules: Int, findings: [BCDReadinessFinding]) -> String {
        "[readiness] \(game): \(modules) program file\(modules == 1 ? "" : "s") read; "
            + (findings.isEmpty ? "nothing missing" : findings.map { $0.id + (($0.fixable) ? "" : "(no fix)") }.joined(separator: ", "))
    }

    /// A program file name for the check's reading of a folder: .exe and .dll only.
    static func isProgram(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "exe" || ext == "dll"
    }

    /// Reads a game folder: every program file's imports (bounded) and every file name. Never follows a symbolic link, never writes, skips the
    /// redistributable folders. `limits` keeps a start from waiting: the page asks on a background queue and shows nothing until it is done.
    static func scan(_ root: URL, maxFiles: Int = 4000, maxModules: Int = 400, seconds: Double = 3.0,
                     now: () -> Date = Date.init) -> (modules: [BCDReadinessModule], files: Set<String>, complete: Bool) {
        let started = now()
        var modules: [BCDReadinessModule] = []
        var files = Set<String>()
        var seen = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return ([], [], false)
        }
        while let item = walker.nextObject() as? URL {
            seen += 1
            if seen > maxFiles || (seen % 128 == 0 && now().timeIntervalSince(started) > seconds) { return (modules, files, false) }
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            let name = item.lastPathComponent.lowercased()
            if values.isDirectory == true {
                if BCDGraphicsScan.skippedFolders.contains(name) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            files.insert(name)
            if isProgram(name), modules.count < maxModules, let info = BCDGraphicsScan.inspect(item) {
                modules.append(BCDReadinessModule(file: item.lastPathComponent, is64: info.is64, imports: info.imports))
            }
        }
        return (modules, files, modules.count < maxModules)
    }
}
