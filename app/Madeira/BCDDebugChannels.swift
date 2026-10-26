// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Wine debug-channel presets for the in-game menu's Tools tab (round 604, B8). A player picks "A program won't load" or "The game
// crashes" instead of one of Wine's 600-odd channels; the choice is written for the NEXT start of any game, used once, and the
// start after it runs as always. Wine's trace channels are heavy (+seh and +file can write thousands of lines a second), which is why
// nothing here is ever left on.
//
// Plain values (tests/host/check-bcd-debug-channels.py compiles this file alone and checks every channel against Wine's source):
//   - the presets and the WINEDEBUG string a set of them makes;
//   - the one-shot file WineProcessBridge.m reads and removes (BCDDebugOnce.fileName, in the app's temporary folder).

struct BCDDebugPreset: Equatable, Identifiable {
    var id: String
    var title: String
    /// What it is for, in the menu's words.
    var detail: String
    /// Wine's channel list: "+loaddll,+module" (every class of those channels).
    var channels: String
    /// Writes a lot: the page says so.
    var heavy = false
}

enum BCDDebugChannels {
    /// What a start runs with when nothing is asked for (WineProcessBridge.m's performance default). A preset's channels are added to it.
    static let base = "err+all,err-virtual,fixme-d3dcompiler"

    static let presets: [BCDDebugPreset] = [
        BCDDebugPreset(id: "loading", title: "A program or a DLL won't load",
                       detail: "Every DLL Wine loads, from where, and whether it is Wine's own or the game's (loaddll, module).",
                       channels: "+loaddll,+module"),
        BCDDebugPreset(id: "crash", title: "The game crashes",
                       detail: "Exceptions as they are raised and handled (seh). Games that throw many exceptions write a lot.",
                       channels: "+seh", heavy: true),
        BCDDebugPreset(id: "process", title: "A launcher starts another program",
                       detail: "Programs and their command lines as Windows starts them (process).",
                       channels: "+process"),
        BCDDebugPreset(id: "files", title: "A file is not found",
                       detail: "Only the warnings of file access: what could not be opened (warn+file).",
                       channels: "warn+file"),
        BCDDebugPreset(id: "sound", title: "No sound, or the wrong sound",
                       detail: "DirectSound, XAudio2, the audio endpoint and winmm (dsound, xaudio2, mmdevapi, winmm).",
                       channels: "+dsound,+xaudio2,+mmdevapi,+winmm", heavy: true),
        BCDDebugPreset(id: "input", title: "A controller or the mouse is ignored",
                       detail: "DirectInput, XInput, HID and raw input (dinput, xinput, hid, rawinput).",
                       channels: "+dinput,+xinput,+hid,+rawinput", heavy: true),
        BCDDebugPreset(id: "network", title: "Online play or a download fails",
                       detail: "Sockets, HTTP and TLS (winsock, winhttp, wininet, secur32).",
                       channels: "+winsock,+winhttp,+wininet,+secur32"),
        BCDDebugPreset(id: "registry", title: "A setting is not found",
                       detail: "The registry keys a program reads and writes (reg).",
                       channels: "+reg", heavy: true),
    ]

    /// Added to any choice: every debug line starts with the time since the start.
    static let timestampChannel = "+timestamp"

    static func preset(_ id: String) -> BCDDebugPreset? { presets.first { $0.id == id } }

    /// The WINEDEBUG a start runs with for the chosen presets (in the order the page lists them), or nil when nothing is chosen.
    static func winedebug(presets chosen: Set<String>, timestamps: Bool) -> String? {
        let picked = presets.filter { chosen.contains($0.id) }
        guard !picked.isEmpty || timestamps else { return nil }
        var parts = [base]
        var seen = Set<String>()
        for preset in picked {
            for channel in preset.channels.split(separator: ",").map(String.init) where seen.insert(channel).inserted { parts.append(channel) }
        }
        if timestamps { parts.append(timestampChannel) }
        return parts.joined(separator: ",")
    }

    /// A WINEDEBUG string the bridge may export: only the characters Wine's syntax uses, and not so long that it is a mistake.
    static func isValid(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 400 else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ",+-_.".contains($0)) }
    }

    /// Whether any chosen preset is a heavy one.
    static func anyHeavy(_ chosen: Set<String>) -> Bool { presets.contains { chosen.contains($0.id) && $0.heavy } }
}

/// The file that carries a plan to the next start. WineProcessBridge.m reads it after the game's own lines, exports its text as WINEDEBUG
/// and removes it, so it applies once. It lives in the app's temporary folder: iOS may clear it, which only means "not asked for".
enum BCDDebugOnce {
    static let fileName = "bcd-debug-once.txt"

    /// What the file holds for a plan, or nil (then the file is removed).
    static func contents(presets: Set<String>, timestamps: Bool) -> String? {
        guard let text = BCDDebugChannels.winedebug(presets: presets, timestamps: timestamps), BCDDebugChannels.isValid(text) else { return nil }
        return text + "\n"
    }
}

/// The plan as the page keeps it between visits (the app's preferences): preset ids, and the time stamps.
struct BCDDebugPlan: Equatable {
    var presets: Set<String> = []
    var timestamps = false

    var isEmpty: Bool { presets.isEmpty && !timestamps }
    var stored: String { presets.sorted().joined(separator: ",") + (timestamps ? ";t" : "") }

    static func parse(_ text: String?) -> BCDDebugPlan {
        guard let text, !text.isEmpty else { return BCDDebugPlan() }
        let halves = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var plan = BCDDebugPlan()
        plan.presets = Set((halves.first ?? "").split(separator: ",").map(String.init).filter { BCDDebugChannels.preset($0) != nil })
        plan.timestamps = halves.count > 1 && halves[1] == "t"
        return plan
    }
}
