// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Round 604, help with a game that does not run well: the values and rules behind three features of a game's page (Options › Help).
//
//  - The guided debug run (D5). A player who has a problem says what it is and what they will do, BCD turns on the detailed log and the
//    performance trace for that one run, starts the game, and when the run is over offers to send its log with those words. Nothing is sent
//    without a tap, and nothing stays turned on: the trace and the detailed log are asked for by the run, never saved as settings.
//  - Game feedback (D7). "How did it run?": a result, what went wrong, a few words, and, if the player agrees, the numbers of the last
//    session. It goes through the Settings › Feedback intake as it is (FeedbackUpload.swift), so the intake and its Worker did not change:
//    the first line of the message is `[game-feedback] result=fine issues=slow,sound game=Hollow Knight`, which tools/pull-logs.py --feedback
//    reads. The player is shown the whole message before it goes.
//
// Plain values only: nothing here touches the engine or UIKit, and tests/host/check-bcd-help.py compiles this file alone. The engine side is
// BCDHelpLive.swift, the page's rows BCDGamePageLiveHelp.swift.

// MARK: - The problem a debug run is about

enum BCDHelpProblem: String, CaseIterable, Identifiable {
    case wontStart, crashes, blackScreen, slow, noSound, controls, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wontStart: return "It does not start"
        case .crashes: return "It crashes or closes"
        case .blackScreen: return "Black or wrong picture"
        case .slow: return "Slow or stutters"
        case .noSound: return "No or wrong sound"
        case .controls: return "Controls do not work"
        case .other: return "Something else"
        }
    }
}

// MARK: - A debug run

/// One guided debug run, kept in the app's defaults from the moment it is armed until its log has been offered (or dropped).
struct BCDDebugRun: Codable, Equatable {
    enum Phase: String, Codable { case armed, running, ended }

    /// The library entry the run is for: the session that starts with this entry is the run.
    var entryID: String
    var title: String
    /// The program's file name, as the session log is named.
    var program: String
    var problem: String
    /// The player's words: what they will do to make it happen.
    var steps: String
    var armedAt: Double
    var phase = Phase.armed
    /// The session log's inode once the run started: the log is found again by it, after a restart too.
    var logInode: UInt64?
    var endedAt: Double?
    /// A Steam game's App ID: such a game's library entry may not be saved yet, and then it has a new id each time it is made, so the run
    /// recognises its session by the App ID too.
    var steamAppID: Int?

    /// Whether the session of a library entry with this id (and App ID) is this run's.
    func matches(entryID id: String, steamAppID app: Int?) -> Bool {
        id == entryID || (steamAppID != nil && steamAppID == app)
    }
}

enum BCDDebugRules {
    static let maxSteps = 600
    /// An armed run whose game did not start (JIT was off, an error) is dropped after ten minutes, so a later ordinary start of that game is
    /// never taken for the run.
    static let armedLifetime: Double = 10 * 60
    /// A finished run is offered for three days.
    static let offerLifetime: Double = 3 * 24 * 3600
    static let defaultsKey = "madeira.bcd.debugrun"

    /// The player's words as they travel: control characters out, a line break a space, the ends trimmed, at most `maxSteps` characters.
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { out.append(" ") }
            else if scalar.properties.generalCategory != .control { out.append(scalar) }
        }
        let words = String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(String.UnicodeScalarView(words.unicodeScalars.prefix(maxSteps)))
    }

    /// What the run is about; nil when the player did not say (an unknown word from another build reads as "something else").
    static func problem(_ run: BCDDebugRun) -> BCDHelpProblem? { run.problem.isEmpty ? nil : (BCDHelpProblem(rawValue: run.problem) ?? .other) }
    static func problemWords(_ run: BCDDebugRun) -> String { problem(run)?.rawValue ?? "not said" }

    /// What the comment box starts with for this run: the problem, and the steps if there are any. One line, at most 2000 characters
    /// (Send Log's limit).
    static func comment(for run: BCDDebugRun) -> String {
        var text = "Guided debug run" + (problem(run).map { ": \($0.title)" } ?? "") + "."
        let steps = clean(run.steps)
        if !steps.isEmpty { text += " What I did: \(steps)" }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(2000)))
    }

    /// A run that was armed and never started is stale after `armedLifetime`.
    static func stale(_ run: BCDDebugRun, now: Double) -> Bool {
        switch run.phase {
        case .armed: return now - run.armedAt > armedLifetime
        case .running: return now - run.armedAt > offerLifetime
        case .ended: return now - (run.endedAt ?? run.armedAt) > offerLifetime
        }
    }

    /// Whether the run is to be offered now: it started, and either ended or was found "running" at the next start of the app (the app
    /// closed during it: the crash question is covered by this one).
    static func offerable(_ run: BCDDebugRun, appJustStarted: Bool, now: Double) -> Bool {
        guard !stale(run, now: now) else { return false }
        switch run.phase {
        case .armed: return false
        case .running: return appJustStarted
        case .ended: return true
        }
    }

    /// The words of the question after a run.
    private static func about(_ run: BCDDebugRun) -> String { problem(run).map { " (\($0.title.lowercased()))" } ?? "" }
    static func offerTitle(_ run: BCDDebugRun, closed: Bool) -> String { closed ? "The debug run closed BCD" : "Debug run finished" }
    static func offerMessage(_ run: BCDDebugRun, closed: Bool) -> String {
        let what = closed
            ? "BCD was closed during the debug run of \(run.title)\(about(run))."
            : "The debug run of \(run.title)\(about(run)) is over."
        return what + " Its log has the detail you asked for, and a performance trace.\n\nSend the log with your notes? "
            + "Folder paths, names and addresses are removed on this device first. Nothing is sent unless you choose Send."
    }

    // MARK: Keeping it

    static func load(_ defaults: UserDefaults = .standard) -> BCDDebugRun? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(BCDDebugRun.self, from: data)
    }

    static func save(_ run: BCDDebugRun?, _ defaults: UserDefaults = .standard) {
        guard let run, let data = try? JSONEncoder().encode(run) else { defaults.removeObject(forKey: defaultsKey); return }
        defaults.set(data, forKey: defaultsKey)
    }
}

// MARK: - Game feedback

enum BCDFeedbackResult: String, CaseIterable, Identifiable {
    case great, fine, hard, broken
    var id: String { rawValue }
    var title: String {
        switch self {
        case .great: return "Runs great"
        case .fine: return "Runs, with small problems"
        case .hard: return "Hard to play"
        case .broken: return "Does not run"
        }
    }
}

enum BCDFeedbackIssue: String, CaseIterable, Identifiable {
    case crashes, picture, slow, sound, controls, loading
    var id: String { rawValue }
    var title: String {
        switch self {
        case .crashes: return "Crashes or closes"
        case .picture: return "Black or wrong picture"
        case .slow: return "Slow or stutters"
        case .sound: return "No or wrong sound"
        case .controls: return "Controls"
        case .loading: return "Very long loading"
        }
    }
}

/// What a player has filled in for one game.
struct BCDGameFeedbackDraft: Equatable {
    var result: BCDFeedbackResult?
    var issues: Set<BCDFeedbackIssue> = []
    var words = ""
    /// The numbers of the game's last session (frame rate, play time, API) go in the message. On by default: they are the point of it,
    /// and the player sees them before it is sent.
    var includeNumbers = true
    /// The game's last log is sent first and its code goes with the message.
    var attachLog = false
}

enum BCDGameFeedbackCore {
    static let tag = "[game-feedback] "
    /// The words part may be this long: the intake takes 4000 characters in all.
    static let maxWords = 3000
    /// The fields of a `[session]` summary line a message may repeat (BCDSessionSummary.line): how the game ran, nothing about the person.
    static let sessionKeys = ["play", "avg", "low1", "low01", "worst", "stalls", "peak", "limit", "thermal", "api", "res", "mfx", "cap"]

    /// A value without spaces, line breaks or the characters the first line uses as separators.
    static func token(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F && $0 != "=" }.map(Character.init))
    }

    /// The game's name for the first line: one line, no control characters, at most 80 characters.
    static func gameName(_ title: String) -> String {
        let flat = BCDDebugRules.clean(title)
        return String(String.UnicodeScalarView(flat.unicodeScalars.prefix(80)))
    }

    /// The numbers line from a `[session]` line's fields (BCDSessionSummary.fields); nil when there is nothing to repeat.
    static func numbersLine(_ fields: [String: String]?) -> String? {
        guard let fields else { return nil }
        let parts = sessionKeys.compactMap { key -> String? in
            guard let value = fields[key], !value.isEmpty else { return nil }
            let clean = token(value)
            return clean.isEmpty ? nil : "\(key)=\(clean)"
        }
        return parts.isEmpty ? nil : "numbers: " + parts.joined(separator: " ")
    }

    /// The whole message: the machine-readable first line, the numbers, then the player's words.
    static func text(game: String, draft: BCDGameFeedbackDraft, numbers: [String: String]?) -> String? {
        guard let result = draft.result else { return nil }
        let issues = BCDFeedbackIssue.allCases.filter { draft.issues.contains($0) }.map(\.rawValue).joined(separator: ",")
        var lines = [tag + "result=\(result.rawValue) issues=\(issues.isEmpty ? "none" : issues) game=\(gameName(game))"]
        if draft.includeNumbers, let line = numbersLine(numbers) { lines.append(line) }
        let words = BCDDebugRules.clean(draft.words)
        if !words.isEmpty {
            lines.append(String(String.UnicodeScalarView(words.unicodeScalars.prefix(maxWords))))
        }
        return lines.joined(separator: "\n")
    }

    struct Parsed: Equatable {
        var result: String
        var issues: [String]
        var game: String
    }

    /// The first line read back (the Python reader, tools/pull-logs.py, does the same).
    static func parse(_ message: String) -> Parsed? {
        guard let first = message.split(whereSeparator: \.isNewline).first, first.hasPrefix(tag) else { return nil }
        var rest = Substring(first.dropFirst(tag.count))
        var result: String?, issues: [String] = [], game: String?
        while !rest.isEmpty {
            if rest.hasPrefix("game=") { game = String(rest.dropFirst(5)); break }
            let (word, tail) = split(rest)
            if let eq = word.firstIndex(of: "=") {
                let key = word[word.startIndex..<eq], value = String(word[word.index(after: eq)...])
                if key == "result" { result = value } else if key == "issues" { issues = value == "none" ? [] : value.split(separator: ",").map(String.init) }
            }
            rest = tail
        }
        guard let result, let game else { return nil }
        return Parsed(result: result, issues: issues, game: game)
    }

    private static func split(_ s: Substring) -> (Substring, Substring) {
        guard let space = s.firstIndex(of: " ") else { return (s, "") }
        return (s[s.startIndex..<space], s[s.index(after: space)...])
    }

    /// The question before it goes: what the message says, as the intake will see it.
    static func confirmation(message: String, attachLog: Bool) -> String {
        "This is the whole message:\n\n\(message)\n\nWith it go the BCD build, the iOS version and the device model."
            + (attachLog ? " The game's last log goes first, cleaned on this device (with its performance trace, if you recorded one), and its code goes with the message." : "")
            + " No name or account."
    }
}
