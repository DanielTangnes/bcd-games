// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The game page's "Help with this game", engine side (BCDGameHelp.swift has the section's words; BCDHelpCore.swift the rules; BCDHelpLive.swift
// the debug run). Engine-bound like BCDGamePageLive.swift, so the preview build leaves it out (tools/ui-preview.py, ENGINE_BOUND).
//
// What the player typed is kept in memory per game while the app runs (a half-written message is not a setting). Starting a debug run
// arms it (BCDDebugRunLive), closes the page, and starts the game through the store. Sending feedback is a Feedback-intake message
// (FeedbackUpload.send, kind "other", first line [game-feedback]); with the log attached, the log goes first (LogUpload.send) and its code
// goes with the message. Neither runs without the player's yes: the page asks with the whole message.

@MainActor final class BCDHelpDrafts {
    static let shared = BCDHelpDrafts()
    var problem: [String: BCDHelpProblem] = [:]
    var steps: [String: String] = [:]
    var feedback: [String: BCDGameFeedbackDraft] = [:]
    var status: [String: String] = [:]
    var sending: Set<String> = []
    /// The fields of the newest `[session]` line of the game's last log, by game id, once looked for (nil: none; absent: not looked for yet).
    var numbers: [String: [String: String]?] = [:]
    var hasLog: [String: Bool] = [:]
    var looking: Set<String> = []
}

extension BCDGamePageLive {
    /// The section for an installed game that has its own program (not the Wine desktop).
    func helpGroup(_ game: BCDGame, _ entry: LibraryEntry) -> BCDGameSettingGroup {
        let drafts = BCDHelpDrafts.shared
        helpLookForNumbers(game)
        var state = BCDHelpState()
        state.problem = drafts.problem[game.id]
        state.steps = drafts.steps[game.id] ?? ""
        state.feedback = drafts.feedback[game.id] ?? BCDGameFeedbackDraft()
        state.status = drafts.status[game.id]
        state.sending = drafts.sending.contains(game.id)
        state.hasLog = drafts.hasLog[game.id] ?? false
        state.readiness = BCDReadinessLive.shared.note(for: entry) { [weak self] in self?.onChange?() }
        state.readinessChecked = BCDReadinessLive.shared.checked(entry)
        if state.feedback.attachLog && !state.hasLog { state.feedback.attachLog = false }
        let numbers = drafts.numbers[game.id] ?? nil
        state.message = BCDGameFeedbackCore.text(game: game.title, draft: state.feedback, numbers: numbers)
        return BCDGameHelp.group(state)
    }

    /// The section's settings: true when `setting` was one of them.
    func helpSet(_ setting: String, to value: String, for game: BCDGame) -> Bool {
        guard setting.hasPrefix("help.") else { return false }
        let drafts = BCDHelpDrafts.shared
        var draft = drafts.feedback[game.id] ?? BCDGameFeedbackDraft()
        switch setting {
        case BCDGameHelp.problem:
            drafts.problem[game.id] = value.isEmpty ? nil : (BCDHelpProblem(rawValue: value) ?? .other)
        case BCDGameHelp.steps:
            drafts.steps[game.id] = BCDDebugRules.clean(value)
        case BCDGameHelp.start:
            helpStartRun(game)
            return true
        case BCDGameHelp.result:
            draft.result = BCDFeedbackResult(rawValue: value)
            drafts.feedback[game.id] = draft
        case BCDGameHelp.words:
            draft.words = String(BCDDebugRules.clean(value).unicodeScalars.prefix(BCDGameFeedbackCore.maxWords))
            drafts.feedback[game.id] = draft
        case BCDGameHelp.numbers:
            draft.includeNumbers = value == "1"
            drafts.feedback[game.id] = draft
        case BCDGameHelp.attach:
            draft.attachLog = value == "1"
            drafts.feedback[game.id] = draft
        case BCDGameHelp.send:
            helpSendFeedback(game)
            return true
        default:
            if let issue = BCDGameHelp.issue(ofID: setting) {
                if value == "1" { draft.issues.insert(issue) } else { draft.issues.remove(issue) }
                drafts.feedback[game.id] = draft
            }
        }
        return true
    }

    // MARK: A debug run

    private func helpStartRun(_ game: BCDGame) {
        guard let entry = entry(for: game), entry.desktop != true else { return }
        let drafts = BCDHelpDrafts.shared
        let run = BCDDebugRun(entryID: entry.id.uuidString, title: game.title,
                              program: entry.launchWindowsPath.split(separator: "\\").last.map(String.init) ?? "",
                              problem: drafts.problem[game.id]?.rawValue ?? "", steps: BCDDebugRules.clean(drafts.steps[game.id] ?? ""),
                              armedAt: Date().timeIntervalSince1970, steamAppID: entry.steamAppID)
        BCDDebugRunLive.shared.arm(run)
        // The page closes and the store starts the game, as Play does.
        onNotice?()
        BCDLiveStore.shared.play(game)
    }

    // MARK: Feedback

    private func helpSendFeedback(_ game: BCDGame) {
        let drafts = BCDHelpDrafts.shared
        guard !drafts.sending.contains(game.id), let draft = drafts.feedback[game.id], draft.result != nil,
              let text = BCDGameFeedbackCore.text(game: game.title, draft: draft, numbers: drafts.numbers[game.id] ?? nil) else { return }
        drafts.sending.insert(game.id)
        drafts.status[game.id] = "Sending…"
        onChange?()
        func finish(_ line: String, sent: Bool) {
            drafts.sending.remove(game.id)
            drafts.status[game.id] = line
            if sent { drafts.feedback[game.id] = BCDGameFeedbackDraft(includeNumbers: draft.includeNumbers) }
            onChange?()
        }
        func post(log: String?) {
            FeedbackUpload.send(kind: "other", text: text, log: log) { result in
                switch result {
                case .success(let code): finish("Sent. Your code: \(code)", sent: true)
                case .failure(let error): finish("Not sent: \(error.localizedDescription) What you wrote is still here.", sent: false)
                }
            }
        }
        guard draft.attachLog else { return post(log: nil) }
        Task { @MainActor [weak self] in
            guard let self, let log = await self.lastLog(of: game) else { return post(log: nil) }
            drafts.status[game.id] = "Getting the log ready…"
            self.onChange?()
            LogUpload.send(log.file, game: LogUpload.game(of: log.file), progress: { line in
                drafts.status[game.id] = line
                self.onChange?()
            }) { result in
                switch result {
                case .success(let code): post(log: code)
                case .failure(let error):
                    finish("The log was not sent: \(error.localizedDescription) Your message is still here. Turn off \u{201C}Send the game's last log\u{201D} to send it alone.", sent: false)
                }
            }
        }
    }

    // MARK: The numbers of the last session

    /// Looks, once a page visit, for the newest `[session]` line in the game's last log (its last 512 KB), on a background queue.
    private func helpLookForNumbers(_ game: BCDGame) {
        let drafts = BCDHelpDrafts.shared
        guard !drafts.looking.contains(game.id), drafts.numbers[game.id] == nil else { return }
        drafts.looking.insert(game.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let log = await self.lastLog(of: game)
            var fields: [String: String]?
            if let log {
                fields = await Task.detached(priority: .utility) { BCDHelpNumbers.lastSession(in: log.file) }.value
            }
            drafts.looking.remove(game.id)
            drafts.numbers[game.id] = .some(fields)
            drafts.hasLog[game.id] = log != nil
            self.onChange?()
        }
    }
}

enum BCDHelpNumbers {
    /// The fields of the newest `[session]` summary in the tail of a log; a whole summary is preferred to a partial one (the app went to the background).
    nonisolated static func lastSession(in log: URL, tailBytes: Int = 512 * 1024) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var partial: [String: String]?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("[session] "), let fields = BCDSessionSummary.fields(String(line)) else { continue }
            if fields["partial"] != "1" { return fields }
            if partial == nil { partial = fields }
        }
        return partial
    }
}
