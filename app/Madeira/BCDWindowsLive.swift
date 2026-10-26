// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The in-game menu's Windows page on the engine (round 604, B1): the list of what Windows has open, bring one to the front, show the desktop
// and bring the windows back. BCDWindows.swift has the words and the order; Winios (Winios.m, driver_ios.c) lists and acts on the Wine side.
//
// Nothing runs until the page is open: opening it switches the list on (winios_windows_set_wanted) and a timer asks for a fresh list once a
// second; closing it, or the menu, or the session, switches both off. The Wine threads look at one relaxed flag per message poll otherwise.
// Engine-bound: the preview build leaves this file out (tools/ui-preview.py, ENGINE_BOUND).

@MainActor final class BCDWindowsLive {
    static let shared = BCDWindowsLive()

    private(set) var windows: [BCDListedWindow] = []
    /// Small pictures of the windows the desktop compositor holds an image of, by window, from the last list (JPEG bytes).
    private(set) var thumbnails: [UInt64: Data] = [:]
    /// Windows this page minimized with "Show the desktop", to bring back.
    private var minimizedByUs: [UInt64] = []
    private var timer: Timer?
    private var commands: [(hwnd: UInt64, kind: Int32)] = []
    private var commandTimer: Timer?
    /// Told when the list changed, so the open page draws it.
    var changed: (() -> Void)?

    /// The session draws a Windows desktop (a Desktop entry, a Dock start, a game started in a Wine desktop): only there does "Show the desktop"
    /// mean something.
    var desktopSession: Bool { ProcessInfo.processInfo.environment["MADEIRA_DESKTOP"] == "1" }

    func start() {
        guard timer == nil else { return }
        winios_windows_set_wanted(1)
        winios_windows_refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The first answer comes a moment after the first poll of a Wine thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tick(request: false) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        commandTimer?.invalidate()
        commandTimer = nil
        commands.removeAll()
        winios_windows_set_wanted(0)
        windows = []
        thumbnails = [:]
    }

    private func tick(request: Bool = true) {
        read()
        if request { winios_windows_refresh() }
    }

    private func read() {
        var raw = [winios_listed_window](repeating: winios_listed_window(), count: Int(WINIOS_WINLIST_MAX))
        let count = Int(winios_windows_copy(&raw, Int32(raw.count)))
        let next = raw.prefix(max(0, min(count, raw.count))).map { window -> BCDListedWindow in
            func text<T>(_ field: T) -> String {
                withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            return BCDListedWindow(hwnd: window.hwnd, pid: window.pid, title: text(window.title), image: text(window.image),
                                   width: Int(window.w), height: Int(window.h), visible: window.visible != 0,
                                   minimized: window.minimized != 0, foreground: window.foreground != 0, metal: window.metal != 0)
        }
        let pictures = Self.pictures(of: next)
        if next != windows || pictures != thumbnails {
            windows = next
            thumbnails = pictures
            changed?()
        }
    }

    /// A small picture of each window that is up (at most the first dozen of the list): only windows the desktop compositor draws have one.
    private static func pictures(of list: [BCDListedWindow]) -> [UInt64: Data] {
        var out: [UInt64: Data] = [:]
        var buffer = [UInt8](repeating: 0, count: 48 * 1024)
        for window in BCDWindowRules.shown(list).filter({ $0.visible }).prefix(12) {
            let n = Int(winios_window_thumbnail(window.hwnd, 192, &buffer, buffer.count))
            if n > 0 { out[window.hwnd] = Data(buffer[0..<n]) }
        }
        return out
    }

    // MARK: Commands

    func bringToFront(_ hwnd: UInt64) {
        winios_windows_command(hwnd, Int32(WINIOS_WINCMD_FRONT))
        LogStore.shared.log("[window-menu] bring \(String(hwnd, radix: 16)) to the front")
    }

    /// Minimizes every window that is up, but not the shell's own: the desktop shows. They are remembered to bring back.
    func showDesktop() {
        let targets = BCDWindowRules.shown(windows).filter { $0.visible && BCDWindowRules.program($0.image) != "explorer.exe" }
        minimizedByUs = targets.map(\.hwnd)
        enqueue(targets.map { ($0.hwnd, Int32(WINIOS_WINCMD_MINIMIZE)) })
        LogStore.shared.log("[window-menu] show the desktop: \(targets.count) window(s) minimized")
    }

    /// Brings back the windows "Show the desktop" minimized.
    func bringBack() {
        let back = minimizedByUs
        minimizedByUs = []
        enqueue(back.map { ($0, Int32(WINIOS_WINCMD_RESTORE)) })
        LogStore.shared.log("[window-menu] \(back.count) window(s) brought back")
    }

    var hasMinimizedByUs: Bool { !minimizedByUs.isEmpty }

    /// One command at a time (Winios keeps a single pending command, taken by the next poll of a Wine thread).
    private func enqueue(_ list: [(hwnd: UInt64, kind: Int32)]) {
        commands += list
        guard commandTimer == nil, !commands.isEmpty else { return }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendNext() }
        }
        RunLoop.main.add(t, forMode: .common)
        commandTimer = t
        sendNext()
    }

    private func sendNext() {
        guard !commands.isEmpty else {
            commandTimer?.invalidate()
            commandTimer = nil
            return
        }
        let next = commands.removeFirst()
        winios_windows_command(next.hwnd, next.kind)
    }
}
