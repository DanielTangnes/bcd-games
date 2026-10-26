// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The "Gestures" page of the in-game menu's Controls tab (round 604, B7): what a finger on the game does, in the words of the pointer
// mode in force. It is a description of MetalBackedView's touch handling (ContentView.swift), so the words follow the three ways that
// handling works:
//   - a game started directly (no Wine desktop): the finger is the mouse. It presses the left button where it touches; moving drags.
//     In "Tap to click" the rules below for it apply instead, in both kinds of session;
//   - a Windows desktop session (Desktop, Dock, "in a Wine desktop"): the Trackpad mode, or Mouse-look;
//   - "Tap to click" (touch mode): one tap clicks where the finger is, hold or move drags, two fingers right-click, three middle-click.
// Plain text and values: no engine or UI type (tests/host/check-bcd-feel.py compiles it alone).

struct BCDGestureHelpSection: Equatable {
    var title: String
    var lines: [String]
}

enum BCDGestureHelp {
    /// - `pointer`: absolute (Trackpad), touch (Tap to click) or relative (Mouse-look), as the menu's "A finger on the game" names them.
    /// - `desktop`: the session draws a Windows desktop (the Trackpad and Mouse-look rules only apply there).
    /// - `touchControls`: the on-screen controls are shown.
    /// - `chord`: how the controller opens this menu.
    static func sections(pointer: String, desktop: Bool, touchControls: Bool, chord: BCDMenuChord) -> [BCDGestureHelpSection] {
        var out: [BCDGestureHelpSection] = [finger(pointer: pointer, desktop: desktop)]
        if touchControls {
            out.append(BCDGestureHelpSection(title: "On-screen controls", lines: [
                "A finger on a control presses it for as long as it stays there; a stick follows the thumb.",
                "A touch that misses every control is the mouse as described above, unless the on-screen controller is shown: then it does nothing (Touches that miss the controls, in this tab, changes that).",
            ]))
        }
        out.append(BCDGestureHelpSection(title: "This menu", lines: [
            "The menu button is the small round button at the top right. Drag it where it is not in the way: it stays there.",
            chordLine(chord),
            "In the menu: D-pad up and down move, A chooses, left and right change a slider, B goes back, LB and RB change the page.",
        ]))
        out.append(BCDGestureHelpSection(title: "Keys", lines: [
            "Game › Keyboard types into the game. Game › Key bar puts Esc, Alt+Tab, Alt+Enter, Win, F1 to F12 and Ctrl, Alt and Shift latches over it.",
        ]))
        return out
    }

    static func finger(pointer: String, desktop: Bool) -> BCDGestureHelpSection {
        switch pointer {
        case "touch":
            return BCDGestureHelpSection(title: "A finger on the game: Tap to click", lines: [
                "One tap: left click where the finger is.",
                "Hold for a quarter of a second, or move: the left button goes down there and the finger drags; lifting drops.",
                "Two fingers tap: right click. Three fingers tap: middle click.",
                "Two fingers drag: the scroll wheel.",
            ])
        case "relative":
            if desktop {
                return BCDGestureHelpSection(title: "A finger on the game: Mouse-look", lines: [
                    "Drag: the mouse moves by how far the finger moves, like turning a camera. Where the finger starts does not matter.",
                    "A tap does not click, so an aiming nudge never fires. Use the on-screen buttons for the mouse buttons.",
                    "Two fingers drag: the scroll wheel.",
                ])
            }
            return BCDGestureHelpSection(title: "A finger on the game: Mouse-look", lines: [
                "In a game started directly the finger is placed on the picture: the pointer jumps where you touch and the left button goes down; moving drags.",
                "Mouse-look moves the mouse by how far a finger moves in a Windows desktop session (Desktop, a Dock start, or a game started in a Wine desktop).",
            ])
        default:
            if desktop {
                return BCDGestureHelpSection(title: "A finger on the game: Trackpad", lines: [
                    "Move one finger: the pointer moves the way it does on a laptop's trackpad, whatever the finger started on.",
                    "Tap: left click. Tap twice quickly: double click.",
                    "Hold the finger still for half a second, then move: the left button is held while it moves; lift to drop.",
                    "Two fingers tap: right click. Two fingers drag: the scroll wheel.",
                ])
            }
            return BCDGestureHelpSection(title: "A finger on the game: the pointer", lines: [
                "In a game started directly the finger is the pointer: it jumps to where you touch and presses the left button; moving drags; lifting lets go.",
                "For taps that click where you tap, with right and middle clicks and scrolling, choose Tap to click in A finger on the game.",
            ])
        }
    }

    static func chordLine(_ chord: BCDMenuChord) -> String {
        switch chord {
        case .backStart:
            return "A controller opens and closes it with Back + Start."
        case .holdStart:
            return "A controller opens it by holding Start for a moment (Back + Start works too). A tap on Start still reaches the game."
        case .holdGuide:
            return "A controller opens and closes it by holding the Home (Guide) button for half a second (Back + Start works too)."
        }
    }
}
