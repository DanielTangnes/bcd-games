// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// How a game starts (round 604): a delay before its program starts, a second program that runs beside it, window rules, and one program
// of its folder run in place of another. The rules and the page's section, with nothing of the engine in them: Foundation only and pure
// (tests/host/check-game-setup.py compiles this file on the Mac and runs it); BCDGameSetup/BCDGameStartLaunch.swift writes the start
// script and the supervisor's file from a plan at a start. BCDStartPlan is read from the game's own file:
//
//     start.delay = 5
//     start.second = C:\Tools\mapper.exe
//     start.second-args = /minimized
//     start.second-stop = 1                (the default: close it when the game has ended; 0 leaves it)
//     window.1 = raise title "Final Fantasy IX" 1000
//     window.2 = minimize-restore class UnityWndClass 0
//     window.3 = opaque title Launcher 250
//
// Window rules act on top-level windows only (bring to the front, minimise and restore, make opaque), once for each window, after the
// delay in milliseconds. No rule can name an anti-cheat or DRM program or window, and no second program can be one: BCD does not help
// anything pass or switch off such a protection. The programs a game starts for its own protection are never swapped (see swap).

/// One window rule.
struct BCDWindowRule: Equatable, Identifiable {
    enum Action: String, CaseIterable { case raise, minimizeRestore = "minimize-restore", opaque }
    enum Match: String { case title, `class` }
    var number: Int
    var action: Action
    var match: Match
    var text: String
    var delayMS: Int
    var id: Int { number }

    var line: String { "\(action.rawValue) \(match.rawValue) \(BCDSetupText.quote(text)) \(delayMS)" }

    var summary: String {
        let what: String
        switch action {
        case .raise: what = "Bring to the front"
        case .minimizeRestore: what = "Minimise, then restore"
        case .opaque: what = "Make opaque"
        }
        return "\(what) the window whose \(match.rawValue) has \"\(text)\"" + (delayMS > 0 ? ", after \(Double(delayMS) / 1000) s" : "")
    }

    static func parse(_ value: String, number: Int) -> (rule: BCDWindowRule?, error: String?) {
        guard let w = BCDSetupText.words(value), w.count == 3 || w.count == 4 else { return (nil, "a rule is: raise, minimize-restore or opaque; title or class; the text; and optionally a delay in milliseconds") }
        guard let action = Action(rawValue: w[0].lowercased()) else { return (nil, "the action is raise, minimize-restore or opaque") }
        guard let match = Match(rawValue: w[1].lowercased()) else { return (nil, "a rule matches the window's title or its class") }
        let text = w[2].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.utf8.count <= 100, !text.contains(where: { "\n\r\0|".contains($0) }) else { return (nil, "the text is 1 to 100 characters, without | or a line break") }
        guard !BCDProtection.names(text) else { return (nil, "a rule never names an anti-cheat or protection program") }
        var delay = 0
        if w.count == 4 {
            guard let n = Int(w[3]), n >= 0, n <= 60_000 else { return (nil, "the delay is 0 to 60000 milliseconds") }
            delay = n
        }
        return (BCDWindowRule(number: number, action: action, match: match, text: text, delayMS: delay), nil)
    }
}

enum BCDProtection {
    /// Names of anti-cheat and DRM programs, as bcd-helper/core.h's hr_is_protection (a host check keeps the two lists equal).
    static let list = [
        "easyanticheat", "easy anti-cheat", "easy anticheat", "eac_launcher", "eosanticheat", "battleye", "beclient", "beservice",
        "vanguard", "vgc.exe", "vgk", "equ8", "xigncode", "nprotect", "gameguard", "punkbuster", "pnkbstr", "faceit", "denuvo",
        "anti-cheat", "anticheat", "anti cheat", "uwssvc", "cheat engine", "ricochet",
    ]

    static func names(_ text: String) -> Bool {
        let t = text.lowercased()
        return list.contains { t.contains($0) }
    }
}

/// What a game's own file asks for at a start.
struct BCDStartPlan: Equatable {
    static let delayKey = "start.delay"
    static let secondKey = "start.second"
    static let secondArgsKey = "start.second-args"
    static let secondStopKey = "start.second-stop"
    static let rulePrefix = "window."
    static let swapKey = "env.MADEIRA_SPAWN_SWAP"
    static let maxRules = 16

    var delay = 0
    var second = ""
    var secondArguments = ""
    var stopSecond = true
    var rules: [BCDWindowRule] = []
    var problems: [String] = []

    /// Nothing is asked for: the game starts as it always did.
    var isEmpty: Bool { delay == 0 && second.isEmpty && rules.isEmpty }
    /// The supervisor runs: a second program to close, or rules.
    var needsSupervisor: Bool { (!second.isEmpty && stopSecond) || !rules.isEmpty }

    static let delayChoices = [0, 3, 5, 10, 15, 30, 60, 120]

    /// A second program: a path on drive C: ending in .exe, or the name of a program of Windows' own folder.
    static func isProgram(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasSuffix(".exe"), t.utf8.count < 260, !t.contains(where: { "\"\n\r\0<>|*?".contains($0) }), !BCDProtection.names(t) else { return false }
        if t.count >= 3, t.prefix(3).uppercased() == "C:\\" { return !t.contains("..") }
        return !t.contains("\\") && !t.contains("/") && !t.contains(":")
    }

    static func read(_ values: [String: String]) -> BCDStartPlan {
        var plan = BCDStartPlan()
        if let text = values[delayKey], !text.isEmpty {
            if let n = Int(text), (0...300).contains(n) { plan.delay = n } else { plan.problems.append("\(delayKey): a whole number of seconds from 0 to 300") }
        }
        if let text = values[secondKey], !text.isEmpty {
            if isProgram(text) { plan.second = text.trimmingCharacters(in: .whitespaces) } else { plan.problems.append("\(secondKey): a program on drive C: ending in .exe (not a protection program)") }
        }
        plan.secondArguments = (values[secondArgsKey] ?? "").trimmingCharacters(in: .whitespaces)
        if plan.secondArguments.contains(where: { "\n\r\0".contains($0) }) || plan.secondArguments.utf8.count > 500 { plan.secondArguments = ""; plan.problems.append("\(secondArgsKey): not valid") }
        plan.stopSecond = values[secondStopKey] != "0"
        for (key, value) in values where key.hasPrefix(rulePrefix) {
            guard let n = Int(key.dropFirst(rulePrefix.count)), (1...99).contains(n) else { plan.problems.append("\(key): the number after the dot is 1 to 99"); continue }
            let parsed = BCDWindowRule.parse(value, number: n)
            if let rule = parsed.rule { plan.rules.append(rule) } else { plan.problems.append("\(key): \(parsed.error ?? "not understood")") }
        }
        plan.rules.sort { $0.number < $1.number }
        if plan.rules.count > maxRules { plan.problems.append("window rules: at most \(maxRules); the rest are left out"); plan.rules = Array(plan.rules.prefix(maxRules)) }
        plan.problems.sort()
        return plan
    }

    static func nextRuleNumber(_ values: [String: String]) -> Int {
        let used = Set(values.keys.compactMap { $0.hasPrefix(rulePrefix) ? Int($0.dropFirst(rulePrefix.count)) : nil })
        return (1...99).first { !used.contains($0) } ?? 99
    }

    // MARK: Swap: one program of the folder run in place of another

    /// "launcher.exe=game.exe" (several separated by ';'): plain program names of one folder, each ending in .exe; never a protection
    /// program on either side (the engine's own list policy also takes plain names only).
    static func swapProblem(_ text: String) -> String? {
        let program = #"[A-Za-z0-9_.()+,~-]([A-Za-z0-9_.()+,~ -]{0,253}[A-Za-z0-9_.()+,~-])?\.[Ee][Xx][Ee]"#
        guard text.range(of: "^" + program + "=" + program + "(;" + program + "=" + program + ")*$", options: .regularExpression) != nil else {
            return "that is not a program name in the form launcher.exe=game.exe (plain names of programs in one folder)"
        }
        if BCDProtection.names(text) { return "BCD does not swap an anti-cheat or protection program" }
        return nil
    }
}

// MARK: - The page's section

struct BCDGameStartState: Equatable {
    var plan = BCDStartPlan()
    var swap = ""
    /// The game's own start (not a Steam game through BCD Dock, not the desktop): delay, second program and rules are offered.
    var ownStart = true
    var notes: [String: String] = [:]
}

enum BCDGameStartPage {
    static let groupID = "start"
    static let delay = "setup.start-delay"
    static let second = "setup.start-second"
    static let secondArgs = "setup.start-second-args"
    static let secondStop = "setup.start-second-stop"
    static let ruleAdd = "setup.start-rule-add"
    static let rulePrefix = "setup.start-rule."
    static let swap = "setup.start-swap"

    static func ruleID(_ number: Int) -> String { rulePrefix + String(number) }
    static func ruleNumber(_ id: String) -> Int? { id.hasPrefix(rulePrefix) ? Int(id.dropFirst(rulePrefix.count)) : nil }

    static func group(_ s: BCDGameStartState) -> BCDGameSettingGroup {
        var list: [BCDGameSetting] = []
        let p = s.plan
        if s.ownStart {
            var delays = BCDStartPlan.delayChoices.map { BCDGameChoice(value: String($0), label: $0 == 0 ? "No delay" : "\($0) seconds") }
            if !BCDStartPlan.delayChoices.contains(p.delay) { delays.append(BCDGameChoice(value: String(p.delay), label: "\(p.delay) seconds")) }
            list.append(BCDGameSetting(id: delay, title: "Wait before the game starts", kind: .choice(delays), value: String(p.delay), defaultValue: "0",
                                       note: s.notes[delay] ?? "BCD starts the game's program this many seconds after the session begins, through a small start script. For a game that needs a service or a second program to be up first."))
            list.append(BCDGameSetting(id: second, title: "Also start this program", kind: .text(prompt: "C:\\Tools\\mapper.exe"), value: p.second,
                                       note: s.notes[second] ?? "A program on drive C: that starts just before the game and runs beside it: a controller mapper, a launcher's helper. It must exist when the game starts, or it is left out. Empty: none."))
            if !p.second.isEmpty {
                list.append(BCDGameSetting(id: secondArgs, title: "Its arguments", kind: .text(prompt: "/minimized"), value: p.secondArguments,
                                           note: s.notes[secondArgs] ?? "Handed to that program."))
                list.append(BCDGameSetting(id: secondStop, title: "Close it when the game has ended", kind: .toggle, value: p.stopSecond ? "1" : "0", defaultValue: "1",
                                           note: "BCD looks at the game's programs every half second while it runs, and closes the second program once none has run for 5 seconds. Off: it is left to end by itself, and BCD waits for it before the session closes."))
            }
            for (index, rule) in p.rules.enumerated() {
                list.append(BCDGameSetting(id: ruleID(rule.number), title: rule.summary,
                                           kind: .choice([BCDGameChoice(value: "on", label: "On"),
                                                          BCDGameChoice(value: "remove", label: "Remove the rule", question: removeQuestion(rule))]),
                                           value: "on", defaultValue: "", note: s.notes[ruleID(rule.number)], heading: index == 0 ? "Window rules" : nil))
            }
            list.append(BCDGameSetting(id: ruleAdd, title: "Add a window rule", kind: .text(prompt: "raise title \"Game name\" 1000"), value: "",
                                       note: s.notes[ruleAdd] ?? "raise, minimize-restore or opaque; title or class; the text to find in it; and a delay in milliseconds. For a launcher window that stays behind the game, a window that comes up black until it is minimised, or one drawn see-through. Never for an anti-cheat or protection program. A game's own windows only: BCD touches nothing else.",
                                       heading: p.rules.isEmpty ? "Window rules" : "New"))
            for (index, problem) in p.problems.enumerated() {
                list.append(BCDGameSetting(id: "setup.start-problem.\(index)", title: "A line BCD cannot read", kind: .info, value: problem))
            }
        }
        list.append(BCDGameSetting(id: swap, title: "Run another program in place of one", kind: .text(prompt: "launcher.exe=game.exe"), value: s.swap,
                                   note: s.notes[swap] ?? "When a program (Steam, a launcher, BCD's start script) is about to start the first program, the second one of the same folder starts instead, as in launcher.exe=game.exe (several separated by semicolons). For a game whose launcher only shows a start button. It does not change the program BCD itself starts first. Never for a program that protects the game. From the next start.",
                                   heading: s.ownStart ? "Programs" : nil))
        let parts = [p.delay > 0 ? "wait \(p.delay) s" : nil, p.second.isEmpty ? nil : "second program", p.rules.isEmpty ? nil : "\(p.rules.count) window rule\(p.rules.count == 1 ? "" : "s")", s.swap.isEmpty ? nil : "swap"].compactMap { $0 }
        return BCDGameSettingGroup(id: groupID, title: "Start", symbol: "play.square.stack", settings: list,
                                   note: s.ownStart ? "What happens around the game's start. Nothing here changes how a game starts until a row is set." : nil,
                                   headline: parts.isEmpty ? "As BCD starts it" : parts.joined(separator: " · "))
    }

    static func removeQuestion(_ rule: BCDWindowRule) -> BCDGameQuestion {
        BCDGameQuestion(title: "Remove this window rule?", message: rule.summary, confirm: "Remove", destructive: true)
    }
}

// MARK: - The start script

/// The cmd batch and the supervisor's file for a start with a plan. Pure text, tested on the Mac; the launch hook writes them to
/// C:\bcd-games and points the session's first program at the batch (the way the services batch has done for the games that need it).
enum BCDStartScript {
    static let folder = "C:\\bcd-games"
    static let helperName = "bcd-helper-x64.exe"
    static var helperPath: String { folder + "\\" + helperName }

    /// Text put into a batch file keeps one line, and '%' is doubled once per expansion (cmd expands '%' in a batch file).
    static func batchText(_ s: String, expansions: Int = 1) -> String {
        var text = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "")
        for _ in 0..<expansions { text = text.replacingOccurrences(of: "%", with: "%%") }
        return text
    }

    /// What the script starts: the game's program, or the services batch that already starts it (startServices).
    enum Main: Equatable {
        case program(path: String, arguments: String, isBatch: Bool)
        case servicesBatch(path: String)
    }

    static func batch(title: String, plan: BCDStartPlan, main: Main, workdir: String, configPath: String, secondExists: Bool, helperPresent: Bool) -> String {
        func q(_ s: String) -> String { "\"\(s)\"" }
        var lines = ["@echo off", "rem Generated by BCD (round 604) for \(batchText(title)); rewritten at every launch."]
        lines.append("cd /d \(q(batchText(workdir)))")
        if secondExists, !plan.second.isEmpty {
            let args = batchText(plan.secondArguments)
            lines.append("start \"\" \(q(batchText(plan.second)))" + (args.isEmpty ? "" : " " + args))
        }
        if helperPresent, plan.needsSupervisor {
            lines.append("start \"\" \(q(helperPath)) supervise \(q(configPath))")
        }
        if helperPresent, plan.delay > 0 {
            lines.append("\(q(helperPath)) wait \(plan.delay)")
        }
        switch main {
        case .servicesBatch(let path):
            lines.append("call \(q(batchText(path)))")
        case .program(let path, let arguments, let isBatch):
            let expansions = isBatch ? 2 : 1
            let target = q(batchText(path, expansions: expansions))
            let extra = batchText(arguments.trimmingCharacters(in: .whitespaces), expansions: expansions)
            let run = isBatch ? "call \(target)" : "start \"\" \(target)"
            lines.append(extra.isEmpty ? run : run + " " + extra)
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The supervisor's file (bcd-helper/core.h reads it).
    static func supervisorFile(plan: BCDStartPlan, game: String, program: String, log: String) -> String {
        func name(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").last.map(String.init) ?? path }
        var lines = ["# Generated by BCD (round 604); rewritten at every launch.", "game=\(game)", "program=\(name(program))"]
        if !plan.second.isEmpty { lines.append("second=\(name(plan.second))") }
        lines.append("stop=\(plan.stopSecond ? 1 : 0)")
        lines.append("wait=\(plan.delay)")
        if !log.isEmpty { lines.append("log=\(log)") }
        for rule in plan.rules { lines.append("rule=\(rule.action.rawValue)|\(rule.match.rawValue)|\(rule.text)|\(rule.delayMS)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
