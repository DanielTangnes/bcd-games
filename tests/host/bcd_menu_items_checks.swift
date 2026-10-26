// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-menu-items.py (round 604). That script compiles this file as main.swift together with the plain
// Swift files of the in-game menu items (BCDSessionFeel, BCDDebugChannels, BCDGestureHelp, BCDMagnifier, BCDWindows,
// BCDOrientation) and the production layout of GuestDisplay.swift, and runs it. The Wine source tree's path, when there is one, is argv[1].
import Foundation
import CoreGraphics

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

// ---- defaults: every value is "as BCD has always done it" ---------------------------------------------------------------------
require(BCDSessionFeel() == BCDSessionFeel() && BCDSessionFeel().isEmpty, "a game with nothing saved has an empty set")
require(BCDTouchFeel.haptics && BCDTouchFeel.tint == nil && !BCDTouchFeel.controlsHidden, "the touch drawing's flags start as always: tick on, BCD's violet, controls shown")
require(BCDHideAfter.clamp(nil) == nil && BCDHideAfter.clamp(0) == nil && BCDHideAfter.clamp(7) == nil && BCDHideAfter.clamp(-3) == nil,
        "no time, zero or a time the menu does not offer never hides the controls")
require(BCDHideAfter.clamp(10) == 10 && BCDHideAfter.seconds.first == 0 && BCDHideAfter.choices.first?.title == "Never", "the times the menu offers, Never first")
require(BCDControlColor(rawValue: "") == .violet && BCDControlColor.violet.rgb == nil && BCDControlColor.allCases.dropFirst().allSatisfy { $0.rgb != nil },
        "violet is the default and leaves the palette alone; every other colour has a value")
require(BCDTouchMouse(rawValue: "") == .automatic && BCDPictureFilter(rawValue: "") == .smooth
        && BCDMenuChord(rawValue: "") == .backStart, "the empty word is the default of every choice")
require(BCDChordSetting.mode == .backStart, "the controller opens the menu with Back + Start unless the player chose another way")

// ---- a game's saved set ----------------------------------------------------------------------------------------------------------
var dirty = BCDSessionFeel()
dirty.hideAfter = 7; dirty.controlColor = "chartreuse"; dirty.touchMouse = "x"; dirty.filter = "fuzzy"; dirty.pointerMode = "swipe"
dirty.touchSpeed = .infinity; dirty.touchHaptics = true; dirty.phoneVibration = false; dirty.eco = false; dirty.orientation = "off"
require(dirty.sanitized().isEmpty, "a set of unknown words, a time the menu does not offer and values equal to the defaults sanitizes to nothing")
var kept = BCDSessionFeel()
kept.hideAfter = 5; kept.controlColor = "green"; kept.touchMouse = "0"; kept.filter = "sharp"; kept.pointerMode = "touch"; kept.touchSpeed = 3.5
kept.touchHaptics = false; kept.phoneVibration = true; kept.eco = true
require(kept.sanitized() == kept, "every real choice is kept as it is")
var fast = BCDSessionFeel(); fast.touchSpeed = 99
require(near(fast.sanitized().touchSpeed ?? 0, 8) && near({ var s = BCDSessionFeel(); s.touchSpeed = 0.001; return s.sanitized().touchSpeed ?? 0 }(), 0.1), "the touch speed is kept in range")
require(kept.words.count >= 8 && BCDSessionFeel().words.isEmpty, "the note under Save lists what is saved, and nothing for an empty set")

let key = BCDSessionFeelFile.key(forWindowsPath: " C:\\Games\\Foo\\Foo.EXE ")
require(key == "c:\\games\\foo\\foo.exe", "a game's key is its Windows path in lower case")
let file = BCDSessionFeelFile.encode([key: kept, "c:\\empty.exe": BCDSessionFeel(), "c:\\bad.exe": dirty])
require(file != nil, "the file encodes")
let back = BCDSessionFeelFile.decode(file)
require(back.count == 1 && back[key] == kept, "empty and all-unknown sets are not written; a real one reads back as it was")
require(BCDSessionFeelFile.decode(nil).isEmpty && BCDSessionFeelFile.decode(Data("not json".utf8)).isEmpty, "a missing or broken file is no sets, not an error")
let newer = Data(#"{"c:\\x.exe": {"hideAfter": 5, "somethingNewer": [1,2,3]}}"#.utf8)
require(BCDSessionFeelFile.decode(newer)["c:\\x.exe"]?.hideAfter == 5, "a newer build's extra keys are ignored")
let tampered = Data(#"{"c:\\x.exe": {"hideAfter": 9999, "controlColor": "pink", "filter": "sharp"}}"#.utf8)
require(BCDSessionFeelFile.decode(tampered)["c:\\x.exe"]?.hideAfter == nil && BCDSessionFeelFile.decode(tampered)["c:\\x.exe"]?.controlColor == "pink",
        "a hand-edited time the menu does not offer is dropped on reading, the rest kept")

// ---- the touch tint --------------------------------------------------------------------------------------------------------------
let revision = BCDTouchFeel.tintRevision
BCDTouchFeel.setTint(.violet)
require(BCDTouchFeel.tintRevision == revision, "setting the colour that is already in force draws nothing again")
BCDTouchFeel.setTint(.green)
require(BCDTouchFeel.tint != nil && BCDTouchFeel.tintRevision == revision &+ 1, "a new colour is in force and asks for a redraw once")
BCDTouchFeel.haptics = false
BCDTouchFeel.controlsHidden = true
BCDTouchFeel.reset()
require(BCDTouchFeel.haptics && BCDTouchFeel.tint == nil && !BCDTouchFeel.controlsHidden, "reset puts the touch drawing back as it always was")

// ---- the controller chord ---------------------------------------------------------------------------------------------------------
var tracker = BCDChordTracker()
let start = BCDChordTracker.start, back_ = BCDChordTracker.back
require(!tracker.update(buttons: start, now: 10, mode: .backStart) && !tracker.update(buttons: start, now: 11, mode: .backStart),
        "with Back + Start as the way, holding Start never opens the menu")
tracker.reset()
require(!tracker.update(buttons: start, now: 20, mode: .holdStart), "holding Start: nothing at the first sample")
require(!tracker.update(buttons: start, now: 20.7, mode: .holdStart), "... nor before 0.8 s")
require(tracker.update(buttons: start, now: 20.85, mode: .holdStart), "... it opens after 0.8 s")
require(!tracker.update(buttons: start, now: 21.5, mode: .holdStart) && !tracker.update(buttons: start, now: 25, mode: .holdStart), "... once per hold")
require(!tracker.update(buttons: 0, now: 25.1, mode: .holdStart), "letting go")
require(!tracker.update(buttons: start, now: 26, mode: .holdStart) && tracker.update(buttons: start, now: 26.9, mode: .holdStart), "a second hold opens it again")
tracker.reset()
_ = tracker.update(buttons: start, now: 30, mode: .holdStart)
require(!tracker.update(buttons: start | 0x1000, now: 31, mode: .holdStart), "Start with A held is a game's own chord, not the menu's")
require(!tracker.update(buttons: start, now: 31.1, mode: .holdStart) && tracker.update(buttons: start, now: 32, mode: .holdStart), "... and the hold counts from when A was let go")
tracker.reset()
_ = tracker.update(buttons: start, now: 40, mode: .holdStart)
require(!tracker.update(buttons: start | back_, now: 41, mode: .holdStart), "Back + Start is handled where it always was, not by the hold")
require(!tracker.update(buttons: start, now: 41.5, mode: .holdStart), "a tap on Start (released before 0.8 s) reaches the game and never opens the menu")
tracker.reset()
_ = tracker.update(buttons: start, now: 50, mode: .holdStart)
require(!tracker.update(buttons: start, now: 50.5, mode: .holdGuide) && !tracker.update(buttons: start, now: 52, mode: .holdGuide), "in Hold Home mode Start does nothing")

// ---- flipping the screen -----------------------------------------------------------------------------------------------------------
require(BCDOrientationFlip.next(from: .landscapeRight) == .landscapeCameraRight && BCDOrientationFlip.next(from: .landscapeLeft) == .landscapeCameraLeft
        && BCDOrientationFlip.next(from: .other) == .landscapeCameraLeft, "a flip puts the camera on the other side")
require(BCDOrientationFlip.next(from: .landscapeRight) != .free && BCDOrientationFlip.next(from: .landscapeRight).locked, "the flipped screen is locked, so a flat device cannot turn it back")

// ---- the magnifier ---------------------------------------------------------------------------------------------------------------------
let base = CGRect(x: 100, y: 40, width: 640, height: 360)
let off = BCDMagnifierState()
require(!off.isOn && off.rect(base: base) == base, "at 1x the picture's rectangle is exactly the base, bit for bit")
require(off.unzoom(point: CGPoint(x: 321.5, y: 77.25), base: base) == CGPoint(x: 321.5, y: 77.25), "... and a touch maps exactly as it did")
require(BCDMagnifierState.zooms == [1, 1.5, 2, 3] && BCDMagnifierState.nearestZoom(1.7) == 1.5 && BCDMagnifierState.nearestZoom(2.6) == 3 && BCDMagnifierState.nearestZoom(0) == 1,
        "the zooms the menu offers; a value between them takes the nearest")
let two = off.zoomed(to: 2)
require(two.isOn && two.u == 0.5 && two.v == 0.5, "zooming in keeps the middle")
let big = two.rect(base: base)
require(near(Double(big.width), 1280) && near(Double(big.height), 720) && near(Double(big.midX), Double(base.midX)) && near(Double(big.midY), Double(base.midY)),
        "2x around the middle: twice as large, centred on the place")
var left = two
for _ in 0..<10 { left = left.panned(dx: -1, dy: 0) }
let leftRect = left.rect(base: base)
require(near(Double(leftRect.minX), Double(base.minX)), "panned as far left as it goes, the picture's left edge is on the place's left edge")
var right = two
for _ in 0..<10 { right = right.panned(dx: 1, dy: 1) }
let rightRect = right.rect(base: base)
require(near(Double(rightRect.maxX), Double(base.maxX)) && near(Double(rightRect.maxY), Double(base.maxY)), "... and as far right and down, its right and bottom edges are on the place's")
require(BCDMagnifierState(zoom: 3, u: -4, v: 9).clamped().u >= 0.5 / 3 && BCDMagnifierState(zoom: 3, u: -4, v: 9).clamped().v <= 1 - 0.5 / 3, "a middle out of range is brought back")
require(BCDMagnifierState(zoom: .nan, u: .nan, v: 0.5).clamped() == BCDMagnifierState(zoom: 1, u: 0.5, v: 0.5), "a number that is not a number is 1x in the middle")
let three = BCDMagnifierState(zoom: 3, u: 0.2, v: 0.8).clamped()
require(near(three.visible, 1.0 / 3) && three.zoomed(to: 1).rect(base: base) == base, "back to 1x gives the base again")
require(two.words == "2×" && off.words == "Off" && BCDMagnifierState(zoom: 1.5).words == "1.5×", "the words under the row")

// The enlarged picture and the touch mapping agree: the guest pixel drawn under a finger is the one the finger maps to, at every zoom and place.
let guest = CGSize(width: 1280, height: 720)
let screen = CGRect(x: 0, y: 0, width: 852, height: 393)
let layoutBase = GameSurfaceLayout.rect(guest: guest, bounds: screen, mode: .fit)
var worst = 0.0
for z in BCDMagnifierState.zooms {
    for (u, v) in [(0.5, 0.5), (0.0, 0.0), (1.0, 1.0), (0.3, 0.7), (0.9, 0.2)] {
        let s = BCDMagnifierState(zoom: z, u: u, v: v).clamped()
        let drawn = s.rect(base: layoutBase)
        for (gx, gy) in [(10.0, 10.0), (640.0, 360.0), (1200.0, 700.0), (333.0, 555.0)] {
            // Where that guest pixel is on screen with the picture enlarged; skip pixels that are off screen.
            let p = CGPoint(x: drawn.minX + CGFloat(gx / 1280) * drawn.width, y: drawn.minY + CGFloat(gy / 720) * drawn.height)
            guard screen.contains(p) else { continue }
            let unzoomed = s.unzoom(point: p, base: layoutBase)
            let mapped = GameSurfaceLayout.map(point: unzoomed, guest: guest, bounds: screen, mode: .fit)
            worst = max(worst, abs(Double(mapped.x) - gx), abs(Double(mapped.y) - gy))
        }
    }
}
require(worst < 1.01, "at every zoom and place, a finger over a guest pixel maps to that pixel (worst error \(worst) px)")

// ---- the words and the order of the Windows page ------------------------------------------------------------------------------------
func window(_ hwnd: UInt64, _ title: String, _ image: String, _ w: Int = 640, _ h: Int = 480, visible: Bool = true, minimized: Bool = false, foreground: Bool = false) -> BCDListedWindow {
    BCDListedWindow(hwnd: hwnd, pid: 4, title: title, image: image, width: w, height: h, visible: visible && !minimized, minimized: minimized, foreground: foreground, metal: false)
}
let wins = [
    window(1, "Program Manager", "c:\\windows\\system32\\explorer.exe", 1280, 720),
    window(2, "Steam", "c:\\program files (x86)\\steam\\steam.exe"),
    window(3, "", "c:\\games\\hollow\\hollow.exe", 1280, 720, foreground: true),
    window(4, "Notepad", "c:\\windows\\system32\\notepad.exe", minimized: true),
    window(5, "MSCTFIME UI", "c:\\windows\\system32\\ctfmon.exe", 0, 0),
    window(6, "  ", "c:\\windows\\system32\\explorer.exe", 80, 20),
]
let shownWindows = BCDWindowRules.shown(wins)
require(shownWindows.map(\.hwnd) == [2, 3, 4], "the desktop shell and the empty message windows are not listed")
let ordered = BCDWindowRules.ordered(shownWindows)
require(ordered.map(\.hwnd) == [3, 2, 4], "the one in front first, then the visible ones, then the minimized ones")
require(BCDWindowRules.name(wins[2]) == "hollow.exe" && BCDWindowRules.name(wins[1]) == "Steam", "a window without a title is named by its program")
require(BCDWindowRules.detail(wins[2]) == "hollow.exe · 1280 × 720 · in front" && BCDWindowRules.detail(wins[3]).hasSuffix("minimized"), "the line under a window")
require(BCDWindowRules.hwnd(ofRow: BCDWindowRules.rowID(window(0xABCDEF, "x", ""))) == 0xABCDEF && BCDWindowRules.hwnd(ofRow: "mm.pause") == nil, "a window's row id carries its handle")
require(BCDWindowRules.summary(wins) == "3 open" && BCDWindowRules.summary([wins[1]]) == "1 open", "the count")
require(BCDWindowRules.program("C:\\Windows\\System32\\Notepad.exe") == "Notepad.exe" && BCDWindowRules.program("") == "", "the program's name from a path")

// ---- the Task Manager's list -----------------------------------------------------------------------------------------------------------
let report = "R\t0\t125.5\tc:\\program files\\launcher\\launcher.exe\nR\t1\t3.0\tc:\\windows\\system32\\werfault.exe\nE\t0\t0\t12.0\t30.5\tc:\\setup.exe\nE\t0\tc0000005\t5.0\t9.0\tc:\\crashy.exe\nU\t2\nT\n"
let programs = BCDProgramsRules.parse(report)
require(programs.count == 4 && programs[0].running && programs[0].name == "launcher.exe" && !programs[0].helper && programs[1].helper, "running programs parse, with helpers marked")
require(!programs[2].running && programs[2].status == 0 && programs[3].status == 0xC0000005 && near(programs[3].seconds, 9), "ended programs parse with their status and how long they lived")
require(BCDProgramsRules.detail(programs[0]) == "running for 2 min" && BCDProgramsRules.detail(programs[1]) == "running for 3 s · a helper"
        && BCDProgramsRules.detail(programs[2]) == "ended normally after 30 s" && BCDProgramsRules.detail(programs[3]) == "ended with status 0xC0000005 after 9 s", "the words for each")
require(BCDProgramsRules.parse("").isEmpty && BCDProgramsRules.parse("garbage\n\n").isEmpty, "an empty or broken snapshot is no programs")
require(BCDProgramsRules.duration(4000) == "1 h 6 min", "hours and minutes")

// ---- the gestures page -------------------------------------------------------------------------------------------------------------
for pointer in ["absolute", "touch", "relative"] {
    for desktop in [false, true] {
        let s = BCDGestureHelp.sections(pointer: pointer, desktop: desktop, touchControls: true, chord: .backStart)
        require(s.count == 4 && s.allSatisfy { !$0.title.isEmpty && !$0.lines.isEmpty && $0.lines.allSatisfy { !$0.isEmpty } }, "the page for \(pointer), desktop \(desktop): every section has words")
    }
}
let touchPage = BCDGestureHelp.finger(pointer: "touch", desktop: false)
require(touchPage.lines.joined().contains("Two fingers tap: right click") && touchPage.lines.joined().contains("scroll"), "Tap to click: right click and scroll are described")
let pad = BCDGestureHelp.finger(pointer: "absolute", desktop: true)
require(pad.lines.joined().contains("laptop") && pad.lines.joined().contains("Tap twice"), "Trackpad: the laptop's way")
let direct = BCDGestureHelp.finger(pointer: "absolute", desktop: false)
require(direct.lines.joined().contains("started directly"), "a game started directly: the finger is the pointer")
let look = BCDGestureHelp.finger(pointer: "relative", desktop: true)
require(look.lines.joined().contains("A tap does not click"), "Mouse-look: a tap does not click (as the handler does)")
require(BCDGestureHelp.sections(pointer: "touch", desktop: false, touchControls: false, chord: .backStart).count == 3, "no controls, no controls section")
require(BCDGestureHelp.chordLine(.backStart).contains("Back + Start") && BCDGestureHelp.chordLine(.holdStart).contains("holding Start") && BCDGestureHelp.chordLine(.holdGuide).contains("Home"),
        "the chord's words follow the choice")

// ---- Wine debug channels -----------------------------------------------------------------------------------------------------------
require(BCDDebugChannels.winedebug(presets: [], timestamps: false) == nil, "nothing chosen is no WINEDEBUG (the start runs as always)")
require(BCDDebugChannels.winedebug(presets: ["loading"], timestamps: false) == "err+all,err-virtual,fixme-d3dcompiler,+loaddll,+module", "a preset adds its channels to the usual WINEDEBUG")
require(BCDDebugChannels.winedebug(presets: ["loading", "crash"], timestamps: true) == "err+all,err-virtual,fixme-d3dcompiler,+loaddll,+module,+seh,+timestamp",
        "several presets in the page's order, time stamps last")
require(BCDDebugChannels.winedebug(presets: [], timestamps: true) == "err+all,err-virtual,fixme-d3dcompiler,+timestamp", "time stamps alone")
require(BCDDebugChannels.winedebug(presets: ["nonsense"], timestamps: false) == nil, "an unknown preset is nothing")
require(Set(BCDDebugChannels.presets.map(\.id)).count == BCDDebugChannels.presets.count, "preset ids are unique")
require(BCDDebugChannels.presets.allSatisfy { BCDDebugChannels.isValid($0.channels) && !$0.title.isEmpty && !$0.detail.isEmpty }, "every preset is plain channel text with words")
require(BCDDebugChannels.presets.allSatisfy { p in
    BCDDebugChannels.isValid(BCDDebugChannels.winedebug(presets: [p.id], timestamps: true) ?? "")
}, "every preset makes a valid WINEDEBUG")
require(!BCDDebugChannels.isValid("") && !BCDDebugChannels.isValid("err+all; rm -rf") && !BCDDebugChannels.isValid("+loaddll\nX=1") && !BCDDebugChannels.isValid(String(repeating: "a", count: 401))
        && BCDDebugChannels.isValid("err+all,+seh"), "only channel text is valid")
require(BCDDebugChannels.anyHeavy(["crash"]) && !BCDDebugChannels.anyHeavy(["loading", "files"]), "heavy presets are named")
let plan = BCDDebugPlan(presets: ["crash", "loading"], timestamps: true)
require(plan.stored == "crash,loading;t" && BCDDebugPlan.parse(plan.stored) == plan && BCDDebugPlan.parse(nil).isEmpty && BCDDebugPlan.parse("bogus,loading").presets == ["loading"],
        "the plan round-trips through the preferences; a stored unknown preset is dropped")
require(BCDDebugOnce.contents(presets: ["loading"], timestamps: false) == "err+all,err-virtual,fixme-d3dcompiler,+loaddll,+module\n" && BCDDebugOnce.contents(presets: [], timestamps: false) == nil,
        "the one-shot file holds the text, or nothing")
// Every channel is one Wine really has (the source tree, when there is one).
if CommandLine.arguments.count > 1 {
    let wine = CommandLine.arguments[1]
    let fm = FileManager.default
    var names = Set<String>()
    for dir in ["dlls", "programs", "server"] {
        guard let walker = fm.enumerator(atPath: wine + "/" + dir) else { continue }
        for case let path as String in walker where path.hasSuffix(".c") {
            guard let text = try? String(contentsOfFile: wine + "/" + dir + "/" + path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("DEBUG_CHANNEL(") {
                if let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close { names.insert(String(line[line.index(after: open)..<close])) }
            }
        }
    }
    require(names.count > 300, "the Wine source has its channels (\(names.count) found)")
    for preset in BCDDebugChannels.presets {
        for channel in preset.channels.split(separator: ",") {
            let name = String(channel.split(separator: "+").last ?? channel)
            require(names.contains(name), "preset \(preset.id): channel \(name) exists in Wine")
        }
    }
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
