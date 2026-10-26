// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Pause and resume the game from the in-game menu (round 604, B3).
//
// How a Windows game is stopped on iOS. Wine's own way (NtSuspendProcess, which the Android ports send SIGSTOP for) does not work here: the
// signal that makes a Wine thread wait never reaches it on iOS (build/wineserver/mach_ios.c, "POSIX signal suspend does NOT deliver on iOS"),
// and suspending the process's threads with Mach calls could stop one inside the allocator's lock and freeze the app's own threads behind it.
// So the game is stopped where it hands a frame over: the present path (winemetal's present, through BCDPauseGate.c's bcd_pause_set) waits
// while the gate is shut, and the thread that draws the game stops at its next Present. The picture on screen stays as it is, the GPU and the
// processor go quiet within a frame or two, and the game's other threads run until they wait for that one (most games wait for it at once).
// The audio endpoint plays silence and mixes nothing while paused (madeira_audio_set_paused in audio_null_ios.c), so each sound stops where it
// is and goes on from there.
//
// What it cannot do: stop a program that presents nothing through Direct3D (a Windows desktop, a game that is loading, a launcher); the menu
// says "Pause takes effect at the game's next frame" and shows the state the gate really has. Windows' clocks keep running while paused
// (QueryPerformanceCounter, GetTickCount), so a game that measures real time sees one long frame when it is resumed; most clamp it. A game
// that talks to a server will not like a long pause.
//
// Never left on: the gate opens when the player resumes, before a quit is asked of the game, when the session ends, and when a session begins.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

enum BCDPauseLive {
    /// The player's state. Main thread.
    nonisolated(unsafe) private(set) static var paused = false
    /// When the pause was asked for, so that the menu can say a game never reached the gate.
    nonisolated(unsafe) private(set) static var pausedAt = Date.distantPast

    /// The game stands still at its next frame; sound stops where it is.
    static func pause() {
        guard !paused else { return }
        paused = true
        pausedAt = Date()
        madeira_audio_set_paused(1)
        bcd_pause_set(1)
        bcd_phone_rumble_stop()
        LogStore.shared.log("[pause] the game is paused at its next frame")
    }

    static func resume() {
        guard paused else { return }
        paused = false
        bcd_pause_set(0)
        madeira_audio_set_paused(0)
        LogStore.shared.log("[pause] resumed")
    }

    /// Threads that have reached the gate: with the game paused, 0 means no frame has been presented since.
    static var waiting: Int { Int(bcd_pause_waiting()) }

    /// A session begins or ends: the gate is open, whatever state the last one left.
    static func clear() {
        paused = false
        bcd_pause_set(0)
        madeira_audio_set_paused(0)
    }

    /// Whether the game has been drawing frames through Direct3D lately, so that Pause has something to stop: the present counter moved
    /// since the last time anyone asked (the menu asks when it builds its rows, and again every second while open).
    nonisolated(unsafe) private static var lastPresents: UInt64 = 0
    nonisolated(unsafe) private static var lastSeen = Date.distantPast

    static func gameIsDrawing() -> Bool {
        let now = madeira_get_present_count()
        defer { lastPresents = now }
        if now != lastPresents { lastSeen = Date(); return true }
        return Date().timeIntervalSince(lastSeen) < 3
    }
}
