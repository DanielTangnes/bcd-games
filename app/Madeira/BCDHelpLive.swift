// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
import UIKit

// Help with a game, on the engine (values and rules: BCDHelpCore.swift; the page's rows: BCDGamePageLiveHelp.swift).
//
// The guided debug run. The player arms it from a game's page (Options › Help): the game, the problem and what they will do are kept in the
// app's defaults (BCDDebugRules.save). The next session of that game is the run: the performance trace is asked for (BCDPerfTraceLive.guidedRun,
// never saved) and the detailed log is turned on for the session only (the same flag as Settings › Logs › Detailed logs, put back when the
// session ends; the saved setting is never touched, so an app that is closed meanwhile starts with what the player chose). When the session
// ends, or the app comes back after being closed during the run, BCD asks once whether to send that log with the player's notes. A run is
// asked about once; a game that starts meanwhile, or a day with no answer, drops it. Nothing is sent without a tap.
//
// Left out of the preview build (tools/ui-preview.py, ENGINE_BOUND).

@MainActor final class BCDDebugRunLive {
    static let shared = BCDDebugRunLive()

    private(set) var run: BCDDebugRun?
    /// A run that was open when BCD closed is asked about by its own question, so the question about a session that closed unexpectedly
    /// (BCDSessionRecorderLive.recoverUnfinished) leaves that session alone.
    private(set) var coversUnfinished = false
    private var diagnosticsForced = false

    init() {
        run = BCDDebugRules.load()
    }

    // MARK: The page arms and disarms it

    var armed: BCDDebugRun? { run?.phase == .armed ? run : nil }

    func arm(_ new: BCDDebugRun) {
        run = new
        BCDDebugRules.save(new)
        LogStore.shared.log("[debug-run] armed for \(new.title): \(BCDDebugRules.problemWords(new))")
    }

    func disarm() {
        guard run?.phase == .armed else { return }
        run = nil
        BCDDebugRules.save(nil)
    }

    // MARK: A session

    /// A library session starts (BCDSessionRecorderLive.began, before the trace starts).
    func sessionBegan(_ entry: LibraryEntry) {
        guard var current = run, current.phase == .armed else { return }
        let now = Date().timeIntervalSince1970
        if BCDDebugRules.stale(current, now: now) { run = nil; BCDDebugRules.save(nil); return }
        guard current.matches(entryID: entry.id.uuidString, steamAppID: entry.steamAppID) else { return }
        current.phase = .running
        current.logInode = BCDPerfTraceSend.inode(of: LogStore.shared.logFileURL)
        run = current
        BCDDebugRules.save(current)
        BCDPerfTraceLive.guidedRun = true
        if !InputSettings.shared.diagnostics { madeira_set_diag_enabled(1); diagnosticsForced = true }
        let steps = BCDDebugRules.clean(current.steps)
        LogStore.shared.log("[debug-run] started for \(current.title) (\(BCDDebugRules.problemWords(current))): the detailed log"
                            + (diagnosticsForced ? "" : " (already on)") + " and the performance trace are on for this session"
                            + (steps.isEmpty ? "" : "; the player will: \(steps)"))
    }

    /// The session ends (BCDSessionRecorderLive.ended, after the trace is closed).
    func sessionEnded() {
        BCDPerfTraceLive.guidedRun = false
        if diagnosticsForced { madeira_set_diag_enabled(InputSettings.shared.diagnostics ? 1 : 0); diagnosticsForced = false }
        guard var current = run, current.phase == .running else { return }
        current.phase = .ended
        current.endedAt = Date().timeIntervalSince1970
        run = current
        BCDDebugRules.save(current)
        LogStore.shared.log("[debug-run] finished for \(current.title)")
        BCDDebugRunPrompt.shared.schedule(current, closed: false)
    }

    /// BCD starts (BCDSessionRecorder.appStarted): a run that was open when the app closed is asked about now.
    func appStarted() {
        guard let current = run else { return }
        let now = Date().timeIntervalSince1970
        if BCDDebugRules.stale(current, now: now) { run = nil; BCDDebugRules.save(nil); return }
        guard BCDDebugRules.offerable(current, appJustStarted: true, now: now) else { return }
        coversUnfinished = current.phase == .running
        var asked = current
        asked.phase = .ended
        asked.endedAt = asked.endedAt ?? now
        run = asked
        BCDDebugRules.save(asked)
        LogStore.shared.log("[debug-run] \(current.phase == .running ? "BCD closed during the run of" : "the run of") \(current.title) is waiting for its question")
        BCDDebugRunPrompt.shared.schedule(asked, closed: current.phase == .running)
    }

    /// The run is over (asked about, answered or dropped): nothing is kept.
    func finish() {
        run = nil
        BCDDebugRules.save(nil)
    }
}

// MARK: - The question after a run

/// "Debug run finished. Send the log with your notes?" Once, when the library's own screen is free, as BCDCrashPrompt waits for it.
@MainActor final class BCDDebugRunPrompt {
    static let shared = BCDDebugRunPrompt()
    private var timer: Timer?
    private var run: BCDDebugRun?
    private var closed = false
    private var tries = 0

    func schedule(_ run: BCDDebugRun, closed: Bool) {
        self.run = run
        self.closed = closed
        tries = 0
        timer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.look() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func look() {
        tries += 1
        let library = LibraryModel.shared
        // A game started, or five minutes went by: the run is dropped (one question per run).
        if tries > 100 || library.current != nil { drop(); return }
        guard library.error == nil, library.restartNotice == nil, UIApplication.shared.applicationState == .active,
              let top = BCDCrashPrompt.presenter() else { return }
        timer?.invalidate()
        timer = nil
        present(on: top)
    }

    private func drop() {
        timer?.invalidate()
        timer = nil
        run = nil
        BCDDebugRunLive.shared.finish()
    }

    private func present(on top: UIViewController) {
        guard let run else { return }
        let log = BCDSessionRecorderLive.findLog(inode: run.logInode ?? 0)
        let alert = UIAlertController(title: BCDDebugRules.offerTitle(run, closed: closed), message: BCDDebugRules.offerMessage(run, closed: closed),
                                      preferredStyle: .alert)
        if let log {
            let send = UIAlertAction(title: "Send log", style: .default) { _ in
                BCDLogComment.prefill = BCDDebugRules.comment(for: run)
                BCDLogComment.ask(for: log, { comment in
                    LogUpload.send(log, game: LogUpload.game(of: log), comment: comment, done: { result in
                        BCDCrashPrompt.report(result)
                    })
                }, cancelled: nil)
            }
            alert.addAction(send)
            alert.preferredAction = send
        }
        alert.addAction(UIAlertAction(title: log == nil ? "OK" : "Not now", style: .cancel))
        top.present(alert, animated: true)
        LogStore.shared.log("[debug-run] asked about the log of \(run.title)\(log == nil ? " (its log is gone)" : "")")
        self.run = nil
        BCDDebugRunLive.shared.finish()
    }
}
