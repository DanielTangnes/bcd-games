// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-players.py. That script compiles this file as main.swift together with
// app/Madeira/BCDPlayers.swift and the plain files it routes through (BCDInputProfile.swift and what it names) and runs it: the
// key a controller is remembered by, which slot a connecting controller takes, how a choice is remembered when two controllers
// change places, the lines a person's choices make, and that with no choice every rule is the first free slot of before.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

// ---- the key a controller is remembered by -----------------------------------------------------------------
let key0 = BCDPlayerSlots.deviceKey(vendor: "Xbox Wireless Controller", category: "Xbox One", ordinal: 0)
let key1 = BCDPlayerSlots.deviceKey(vendor: "Xbox Wireless Controller", category: "Xbox One", ordinal: 1)
require(key0 == "Xbox Wireless Controller|Xbox One|0" && key1 == "Xbox Wireless Controller|Xbox One|1" && key0 != key1, "name, kind and number among the same kind")
require(BCDPlayerSlots.deviceKey(vendor: "A|B", category: " X ", ordinal: -3) == "A/B|X|0", "a bar in a name is replaced, spaces trimmed, a number below zero is zero")
require(BCDPlayerSlots.deviceKey(vendor: "DualSense Wireless Controller", category: "DualSense", ordinal: 0) != key0, "another controller, another key")

// ---- which slot a connecting controller takes -----------------------------------------------------------------
require(BCDPlayerSlots.choose(preferred: [], occupied: [false, false, false, false]) == 0, "no choice: the first free slot")
require(BCDPlayerSlots.choose(preferred: [], occupied: [true, false, true, false]) == 1, "... the first free one, as it always was")
require(BCDPlayerSlots.choose(preferred: [], occupied: [true, true, true, true]) == nil, "... none when all four are taken")
require(BCDPlayerSlots.choose(preferred: [2], occupied: [false, false, false, false]) == 2, "a controller goes to the slot it was chosen for")
require(BCDPlayerSlots.choose(preferred: [2], occupied: [false, false, true, false]) == 0, "... which, taken, sends it to the first free one")
require(BCDPlayerSlots.choose(preferred: [3, 1], occupied: [false, false, false, true]) == 1, "two remembered slots: the first free one of them")
require(BCDPlayerSlots.choose(preferred: [7, -1], occupied: [false, true, true, true]) == 0, "a slot that does not exist is ignored")
require(BCDPlayerSlots.choose(preferred: [], occupied: []) == nil && BCDPlayerSlots.choose(preferred: [1], occupied: [false]) == 0, "a short list of slots is read as it is")
for mask in 0..<16 {
    let occupied = (0..<4).map { mask & (1 << $0) != 0 }
    require(BCDPlayerSlots.choose(preferred: [], occupied: occupied) == occupied.firstIndex(of: false), "slots \(mask): with no choice, exactly the first free slot")
}

// ---- remembering a choice ------------------------------------------------------------------------------------
let a = "A|k|0", b = "B|k|0", c = "C|k|0"
require(BCDPlayerSlots.assigning([:], key: a, to: 1, left: 0, displaced: nil) == [1: a], "a controller put in a free slot is remembered there")
require(BCDPlayerSlots.assigning([0: a, 1: b], key: b, to: 0, left: 1, displaced: a) == [0: b, 1: a], "two controllers change places: both are remembered")
require(BCDPlayerSlots.assigning([0: a], key: a, to: 2, left: 0, displaced: nil) == [2: a], "a controller is remembered in one slot only")
require(BCDPlayerSlots.assigning([0: a, 2: c], key: b, to: 2, left: 1, displaced: c) == [0: a, 2: b, 1: c], "the third controller changes places with the one in the slot")
require(BCDPlayerSlots.assigning([0: a], key: a, to: 0, left: 0, displaced: nil) == [0: a], "choosing the slot a controller is in remembers it")
require(BCDPlayerSlots.assigning([1: c], key: a, to: 1, left: 0, displaced: c) == [1: a, 0: c], "a remembered controller that was displaced goes to the slot the first one left")
require(BCDPlayerSlots.assigning([0: a, 1: b], key: c, to: 1, left: 2, displaced: nil) == [0: a, 1: c], "a controller in an occupied remembered slot takes it")

// ---- the lines a person's choices make ------------------------------------------------------------------------
func players(_ lines: [String: String]) -> BCDPlayerSettings { BCDPlayerSettings.parse { lines[$0] } }
require(players([:]) == BCDPlayerSettings() && players([:]).isStandard, "no lines: nothing remembered, full rumble, the touch controls are Player 1")
require(players(["p2-pad": key0]).assigned == [1: key0] && players(["p2-pad": "no bar here"]).assigned.isEmpty && players(["p2-pad": ""]).assigned.isEmpty,
        "a remembered controller needs the shape of a key")
require(players(["p1-rumble": "50"]).rumble == [0: 50] && players(["p1-rumble": "0"]).rumble == [0: 0], "rumble 50 and off")
require(players(["p1-rumble": "100"]).rumble.isEmpty && players(["p1-rumble": "33"]).rumble.isEmpty && players(["p1-rumble": "x"]).rumble.isEmpty, "full or anything else is the default")
require(players(["p3-rumble": "25"]).rumblePercent(2) == 25 && players([:]).rumblePercent(2) == 100, "rumblePercent")
require(players(["p3-rumble": "25"]).rumbleScale(2) == 0.25 && players([:]).rumbleScale(0) == 1 && players(["p1-rumble": "0"]).rumbleScale(0) == 0, "the factor on the motors")
require(players(["touch-player": "2"]).touchSlot == 1 && players(["touch-player": "4"]).touchSlot == 3 && players(["touch-player": "5"]).touchSlot == 0
        && players(["touch-player": "0"]).touchSlot == 0 && players(["touch-player": "one"]).touchSlot == 0, "the touch controls' player")
require(players(["touch-player": "3"]).touchLine == "3" && players([:]).touchLine == "", "touchLine")
require(players(["p1-pad": key0, "p3-pad": key0]).preferredSlots(for: key0) == [0, 2] && players([:]).preferredSlots(for: key0).isEmpty, "the slots a controller was remembered for")
require(!players(["touch-player": "2"]).isStandard && !players(["p1-rumble": "0"]).isStandard && !players(["p1-pad": key0]).isStandard, "any choice makes it not the standard")
require(BCDPlayerSettings.lineNames.count == 9 && Set(BCDPlayerSettings.lineNames).count == 9, "nine lines")
require(BCDPlayerSettings.rumbleChoices == [100, 75, 50, 25, 0], "rumble choices from full to off")
require(BCDPlayerWords.rumble(100) == "Full" && BCDPlayerWords.rumble(0) == "Off" && BCDPlayerWords.rumble(75) == "75%", "words")
require(BCDPlayerSlots.title(0) == "Player 1" && BCDPlayerSlots.title(3) == "Player 4", "titles")

// ---- routing -----------------------------------------------------------------------------------------------------
require(BCDInputLines.feature(of: "p2-pad") == "players" && BCDInputLines.feature(of: "touch-player") == "players" && BCDInputLines.feature(of: "p4-rumble") == "players", "the lines belong to the players")
require(BCDInputLines.global.contains("players") && !BCDInputLines.global.contains("turbo"), "players are for every game, turbo is for a game")
func write(_ s: String, _ v: String) -> (feature: String, line: String, value: String)? { BCDInputLines.write(setting: s, value: v) { _, _ in nil } }
require(write("p1-rumble", "100")?.value == "" && write("p1-rumble", "50")?.value == "50" && write("touch-player", "1")?.value == "" && write("touch-player", "2")?.value == "2",
        "full rumble and Player 1 are the absence of a line")
require(BCDInputLines.handles("p3-rumble") && BCDInputLines.handles("touch-player") && !BCDInputLines.handles("resolution"), "a setting is looked at before any game entry is")
let snapshot = BCDPlayersSnapshot()
require(snapshot.rows.count == 4 && snapshot.connected == 0 && snapshot.listening == nil && snapshot.touchSlot == 0, "an empty snapshot")
var one = BCDPlayersSnapshot(); one.rows[1].name = "Pad"
require(one.connected == 1 && BCDPlayerRow(slot: 2).title == "Player 3", "a snapshot with one controller")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
