// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// "Help with this game" on a game's page (round 604): the section of Options in BCD's words. No views and no engine types, like
// the save backups section: the live backend (BCDGamePageLiveHelp.swift) fills the state in, the page's own lists draw the section from the
// settings below, and the preview app can build it from sample state.
//
// Three things: a debug run (say what goes wrong and what you will do; BCD starts the game with more detail recorded and offers to send the
// log with your notes afterwards), "How did it run?" (a result, what went wrong and a few words go to BCD through the Feedback intake, after
// the whole message is shown), and the launch check (what the game's programs want that this device does not have yet).

/// What the section shows, filled in by the live backend.
struct BCDHelpState: Equatable {
    /// nil: the player did not say.
    var problem: BCDHelpProblem?
    var steps = ""
    var feedback = BCDGameFeedbackDraft()
    /// The message "Send feedback" would send, as the intake sees it; nil until a result is chosen.
    var message: String?
    /// What the last feedback did ("Sent. Your code: K7Q2MX", a reason, "Sending…").
    var status: String?
    var sending = false
    /// The game has a log from an earlier session (the feedback may send it, and carries its numbers).
    var hasLog = false
    /// The launch check's note, or nil when nothing is missing (or the check has not finished).
    var readiness: String?
    var readinessChecked = false
}

enum BCDGameHelp {
    static let groupID = "help"
    static let problem = "help.problem"
    static let steps = "help.steps"
    static let start = "help.start"
    static let result = "help.fb.result"
    static let issuePrefix = "help.fb.issue."
    static let words = "help.fb.words"
    static let numbers = "help.fb.numbers"
    static let attach = "help.fb.log"
    static let send = "help.fb.send"
    static let status = "help.fb.status"
    static let ready = "help.ready"

    static func issueID(_ issue: BCDFeedbackIssue) -> String { issuePrefix + issue.rawValue }
    static func issue(ofID id: String) -> BCDFeedbackIssue? { id.hasPrefix(issuePrefix) ? BCDFeedbackIssue(rawValue: String(id.dropFirst(issuePrefix.count))) : nil }

    static let startQuestion = BCDGameQuestion(
        title: "Start a debug run?",
        message: "BCD turns on the detailed log and the performance trace for this one run and starts the game. When you come back, it asks whether to send the log with your notes; nothing is sent unless you choose Send. A run slows the game a little. Both are off again afterwards.",
        confirm: "Start the game", destructive: false)

    static func headline(_ s: BCDHelpState) -> String {
        if let ready = s.readiness, !ready.isEmpty { return "Something is missing" }
        if s.status?.hasPrefix("Sent") == true { return "Feedback sent" }
        return "Debug run, feedback"
    }

    static func group(_ s: BCDHelpState) -> BCDGameSettingGroup {
        var rows: [BCDGameSetting] = []

        rows.append(BCDGameSetting(
            id: ready, title: "Launch check", kind: .info,
            value: !s.readinessChecked ? "Looking…" : s.readiness == nil ? "Nothing missing" : "See below",
            note: s.readiness ?? "BCD reads which Windows files the game's programs ask for and tells you here, and above Play, when this device does not have one yet. It changes nothing.",
            heading: "Before you play"))

        rows.append(BCDGameSetting(
            id: problem, title: "What goes wrong",
            kind: .choice([BCDGameChoice(value: "", label: "Not said")] + BCDHelpProblem.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
            value: s.problem?.rawValue ?? "", defaultValue: "",
            note: "A debug run records the game's start with more detail than usual.",
            heading: "Debug run"))
        rows.append(BCDGameSetting(
            id: steps, title: "What you will do", kind: .text(prompt: "For example: open the shop, then press Buy"), value: s.steps,
            note: "Optional. These words go with the log if you choose to send it. Please don't write personal details."))
        rows.append(BCDGameSetting(
            id: start, title: "Start a debug run", kind: .action,
            note: "Starts the game now. Afterwards BCD offers to send its log, with your notes and the performance trace (one line a second).",
            question: startQuestion))

        rows.append(BCDGameSetting(
            id: result, title: "How did it run?",
            kind: .choice([BCDGameChoice(value: "", label: "Not chosen")] + BCDFeedbackResult.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
            value: s.feedback.result?.rawValue ?? "", defaultValue: "",
            note: "Tell BCD how this game runs on this device. It helps decide what to fix.",
            heading: "Tell BCD how it ran"))
        for issue in BCDFeedbackIssue.allCases {
            rows.append(BCDGameSetting(id: issueID(issue), title: issue.title, kind: .toggle,
                                       value: s.feedback.issues.contains(issue) ? "1" : "0", defaultValue: "0"))
        }
        rows.append(BCDGameSetting(id: words, title: "In your words", kind: .text(prompt: "Optional: what happened, where"), value: s.feedback.words))
        rows.append(BCDGameSetting(
            id: numbers, title: "Include the last session's numbers", kind: .toggle, value: s.feedback.includeNumbers ? "1" : "0", defaultValue: "1",
            note: s.hasLog ? "Frame rate, play time and graphics API from the summary at the end of this game's last log. No names or paths."
                           : "This game has no log yet, so there are no numbers to include."))
        rows.append(BCDGameSetting(
            id: attach, title: "Send the game's last log with it", kind: .toggle, value: s.feedback.attachLog ? "1" : "0", defaultValue: "0",
            note: "The log is cleaned on this device first, like Send Log. Its code goes with the message.", locked: s.hasLog ? nil : "This game has no log yet."))
        var sendRow = BCDGameSetting(
            id: send, title: s.sending ? "Sending…" : "Send feedback", kind: .action,
            note: "You see the whole message before it goes. The BCD build, iOS version and device model go with it; no name or account.",
            locked: s.sending ? "Sending…" : s.feedback.result == nil ? "Choose how it ran first." : nil)
        if let message = s.message {
            sendRow.question = BCDGameQuestion(title: "Send this feedback?",
                                               message: BCDGameFeedbackCore.confirmation(message: message, attachLog: s.feedback.attachLog && s.hasLog),
                                               confirm: "Send", destructive: false)
        }
        rows.append(sendRow)
        if let status = s.status, !status.isEmpty {
            rows.append(BCDGameSetting(id: self.status, title: "Last feedback", kind: .info, value: "", note: status))
        }

        return BCDGameSettingGroup(id: groupID, title: "Help with this game", symbol: "lifepreserver", settings: rows, headline: headline(s))
    }
}
