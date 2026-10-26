// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-padmodel.py. That script compiles this file as main.swift together with
// app/Madeira/BCDPadModel.swift (plain Foundation) and runs it: the names of what a game can see as the controller, and the value of
// the line each one is.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

require(BCDPadModel.allCases.count == 5 && Set(BCDPadModel.allCases.map(\.rawValue)).count == 5, "five choices, each its own line")
require(BCDPadModel.xbox.line == "" && BCDPadModel.dualSense.line == "dualsense" && BCDPadModel.dualShock.line == "ds4" && BCDPadModel.generic.line == "generic" && BCDPadModel.controller.line == "hid",
        "the lines GamepadInput reads (nothing is XInput, the default)")
require(BCDPadModel.named("") == .xbox && BCDPadModel.named(nil) == .xbox && BCDPadModel.named("xinput") == .xbox && BCDPadModel.named(" XInput ") == .xbox, "no line and \"xinput\" are the Xbox controller")
require(BCDPadModel.named("DualSense") == .dualSense && BCDPadModel.named("ds4") == .dualShock && BCDPadModel.named("generic") == .generic && BCDPadModel.named("hid") == .controller, "the others, any case")
require(BCDPadModel.named("playstation") == nil && BCDPadModel.named("xbox360") == nil, "a value this build does not know is none")
require(!BCDPadModel.xbox.isHID && BCDPadModel.allCases.filter { $0 != .xbox }.allSatisfy(\.isHID), "everything but the Xbox controller leaves XInput")
require(BCDPadModel.allCases.allSatisfy { !$0.title.isEmpty && $0.detail.count > 40 }, "each has words")
require(BCDPadModel.xbox.detail.contains("Xbox 360") && BCDPadModel.xbox.detail.contains("Xbox One"), "the Xbox choice says why 360 and One are one choice")
require(BCDPadModel.choices(dualShock: true).count == 5 && BCDPadModel.choices(dualShock: false).count == 4 && !BCDPadModel.choices(dualShock: false).contains(.dualShock), "the DualShock 4 can be left out of a list")
require(!BCDPadModel.dualShockServed && BCDPadModel.choices() == BCDPadModel.choices(dualShock: false) && !BCDPadModel.choices().contains(.dualShock), "this build serves no DualShock 4, so no list offers one")
require(BCDPadModel.choices().first == .xbox && BCDPadModel.choices().map(\.line) == ["", "dualsense", "generic", "hid"], "the default is first, then the lines GamepadInput reads")
require(BCDPadModel.pageNote.contains("DualSense") && BCDPadModel.pageNote.contains("XInput"), "the page's note says what each choice is")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
