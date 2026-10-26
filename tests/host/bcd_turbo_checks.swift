// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-turbo.py. That script compiles this file as main.swift together with
// app/Madeira/BCDKeyNames.swift, BCDInputPrefs.swift and BCDTurbo.swift (plain Foundation) and runs it: the lines a game's
// turbo and macros make, the clock that decides when a held input is down, the controller gate, the macro player's three
// modes, the presses BCD itself makes, and the repeat of a touch control's key or mouse button.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

// ---- key names -------------------------------------------------------------------------------------------
require(BCDKeyNames.vk("space") == 0x20 && BCDKeyNames.vk(" E ") == 0x45 && BCDKeyNames.vk("F5") == 0x74 && BCDKeyNames.vk("7") == 0x37,
        "key names: space, e, f5, 7 (any case, spaces around)")
require(BCDKeyNames.vk("nonsense") == nil && BCDKeyNames.vk("") == nil, "an unknown name is nothing")
require(BCDKeyNames.parseList("space, e, E, f, nope, 9") == [0x20, 0x45, 0x46, 0x39], "a list drops unknown names and repeats")
require(BCDKeyNames.parseList((1...20).map { _ in "a" }.joined(separator: ",")) == [0x41], "repeats collapse")
require(BCDKeyNames.parseList("a,b,c,d,e,f,g,h,i,j").count == 8, "no more than eight")
require(BCDKeyNames.parseList(BCDKeyNames.listText([0x20, 0x45, 0x74])) == [0x20, 0x45, 0x74] && BCDKeyNames.listText([0x20, 0x45, 0x74]) == "space, e, f5", "listText reads back")
require(Set(BCDKeyNames.table.map(\.name)).count == BCDKeyNames.table.count && Set(BCDKeyNames.table.map(\.vk)).count == BCDKeyNames.table.count,
        "every key has its own name and code")
require(BCDKeyNames.table.count == 19 + 26 + 10 + 12, "19 named keys, 26 letters, 10 digits, 12 function keys")

// ---- the preferences store -------------------------------------------------------------------------------
let suite = "bcd.turbo.test.\(ProcessInfo.processInfo.processIdentifier)"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
let prefs = BCDInputPrefs(defaults: defaults)
require(prefs.lines("turbo", game: "C:\\g.exe").isEmpty, "a game that was never touched has no lines")
prefs.set("turbo", game: "C:\\g.exe", line: "turbo", value: "a,rt")
prefs.set("turbo", game: "C:\\g.exe", line: "turbo-rate", value: "15")
require(prefs.lines("turbo", game: "C:\\g.exe") == ["turbo": "a,rt", "turbo-rate": "15"], "lines are kept by the game's path")
require(prefs.lines("turbo", game: "C:\\other.exe").isEmpty && prefs.lines("look", game: "C:\\g.exe").isEmpty, "... and by the feature")
prefs.set("turbo", game: "C:\\g.exe", line: "turbo-rate", value: "")
require(prefs.lines("turbo", game: "C:\\g.exe") == ["turbo": "a,rt"], "an empty value removes the line")
prefs.set("turbo", game: "C:\\g.exe", line: "turbo", value: "")
require(defaults.dictionary(forKey: "bcd.input.turbo") == nil, "a game with no line left, and no game left, leaves nothing behind")
defaults.removePersistentDomain(forName: suite)

// ---- turbo lines -----------------------------------------------------------------------------------------
func turbo(_ lines: [String: String]) -> BCDTurboSettings { BCDTurboSettings.parse { lines[$0] } }
require(turbo([:]) == BCDTurboSettings() && !turbo([:]).isOn && turbo([:]).rate == 10, "no lines: off, ten a second")
let t1 = turbo(["turbo": "rt, A ,mouse-left", "turbo-keys": "space,e", "turbo-rate": "15"])
require(t1.pad == [.a, .rt] && t1.mouseLeft && !t1.mouseRight && t1.keys == [0x20, 0x45] && t1.rate == 15, "a list of names, in the order of the buttons")
require(t1.padOn && t1.touchOn && t1.isOn, "pad, mouse and keys count")
require(turbo(["turbo": "start,up,nope"]).pad.isEmpty, "only the main ten inputs can repeat")
require(turbo(["turbo": "a,a,a"]).pad == [.a], "a name twice is one")
require(turbo(["turbo-rate": "1"]).rate == 2 && turbo(["turbo-rate": "99"]).rate == 30 && turbo(["turbo-rate": "x"]).rate == 10, "the rate is kept in range")
require(turbo(["turbo-keys": "space"]).touchOn && !turbo(["turbo-keys": "space"]).padOn, "a key alone is for the touch controls")
require(BCDTurboSettings.toggled("", name: "x", on: true) == "x", "switching X on")
require(BCDTurboSettings.toggled("x", name: "a", on: true) == "a,x", "... keeps the order of the buttons")
require(BCDTurboSettings.toggled("a,x", name: "a", on: false) == "x", "... and off")
require(BCDTurboSettings.toggled("x", name: "mouse-left", on: true) == "x,mouse-left" && BCDTurboSettings.toggled("", name: "mouse-right", on: true) == "mouse-right",
        "the mouse buttons")
require(BCDTurboSettings.toggled("mouse-left,mouse-right", name: "mouse-left", on: false) == "mouse-right", "... and off again")
require(BCDTurboSettings.toggled("", name: "start", on: true) == "", "a name that cannot repeat is not added")
require(turbo(["turbo": BCDTurboSettings.toggled("a,rt", name: "b", on: true)]).pad == [.a, .b, .rt], "a toggled line reads back")
require(t1.holds(name: "a") && t1.holds(name: "mouse-left") && !t1.holds(name: "b") && !t1.holds(name: "mouse-right"), "holds(name:)")
require(BCDTurboSettings.rateChoices.allSatisfy { BCDTurboSettings.rateRange.contains($0) }, "every offered rate is in range")

// ---- the clock -------------------------------------------------------------------------------------------
require(BCDTurboClock.period(rate: 10) == 100 && BCDTurboClock.period(rate: 30) == 33 && BCDTurboClock.period(rate: 5) == 200, "periods in milliseconds")
require(BCDTurboClock.isDown(elapsed: 0, rate: 10), "a held input is down at once (a quick tap fires)")
require(BCDTurboClock.isDown(elapsed: 49, rate: 10) && !BCDTurboClock.isDown(elapsed: 50, rate: 10), "... for half a period")
require(!BCDTurboClock.isDown(elapsed: 99, rate: 10) && BCDTurboClock.isDown(elapsed: 100, rate: 10), "... then up, and down again at the next period")
var downMillis = 0
for e in 0..<1000 where BCDTurboClock.isDown(elapsed: e, rate: 10) { downMillis += 1 }
require(downMillis == 500, "ten a second is down half the time")
var edges = 0
var last = true
for e in 0..<1000 { let d = BCDTurboClock.isDown(elapsed: e, rate: 20); if d && !last { edges += 1 }; last = d }
require(edges >= 19 && edges <= 20, "twenty a second gives twenty presses")
require(BCDTurboClock.isDown(elapsed: -5, rate: 10), "a clock that ran backwards still holds the input down")

// ---- the gate --------------------------------------------------------------------------------------------
var gate = BCDTurboGate()
let aTurbo = turbo(["turbo": "a,rt"])
var bits = BCDPadBits()
bits.press(.a)
var again = gate.apply(aTurbo, &bits, now: 1000)
require(again && bits.holds(.a), "A held: down at once")
bits = BCDPadBits(); bits.press(.a)
_ = gate.apply(aTurbo, &bits, now: 1060)
require(!bits.holds(.a), "... let go in the second half of the period")
bits = BCDPadBits(); bits.press(.a)
_ = gate.apply(aTurbo, &bits, now: 1100)
require(bits.holds(.a), "... down again at the next period")
bits = BCDPadBits()
again = gate.apply(aTurbo, &bits, now: 1110)
require(!again && bits.isEmpty, "A let go: nothing held, nothing to sample")
bits = BCDPadBits(); bits.press(.a)
_ = gate.apply(aTurbo, &bits, now: 5000)
require(bits.holds(.a), "A held again later starts a fresh period")
bits = BCDPadBits(); bits.press(.b)
again = gate.apply(aTurbo, &bits, now: 5010)
require(!again && bits.holds(.b), "a button that is not on the list passes untouched")
bits = BCDPadBits(); bits.rt = 200
_ = gate.apply(aTurbo, &bits, now: 6000)
require(bits.rt == 200, "a trigger keeps its own value in the down half")
bits = BCDPadBits(); bits.rt = 200
_ = gate.apply(aTurbo, &bits, now: 6060)
require(bits.rt == 0, "... and is let go in the up half")
bits = BCDPadBits(); bits.rt = 30
again = gate.apply(aTurbo, &bits, now: 7000)
require(!again && bits.rt == 30, "a trigger pulled under a quarter does not count as held")
bits = BCDPadBits(); bits.press(.a); bits.press(.b)
var g2 = BCDTurboGate()
_ = g2.apply(aTurbo, &bits, now: 0)
bits = BCDPadBits(); bits.press(.a); bits.press(.b)
_ = g2.apply(aTurbo, &bits, now: 60)
require(!bits.holds(.a) && bits.holds(.b), "each input is gated on its own")

// ---- macros: lines ---------------------------------------------------------------------------------------
func macros(_ lines: [String: String]) -> BCDMacroSettings { BCDMacroSettings.parse { lines[$0] } }
require(macros([:]).macros.isEmpty && !macros([:]).isOn, "no lines: no macros")
let m1 = macros(["macro1-button": "r3", "macro1-steps": "a, a, lb+a, -, b"])
require(m1.macros.count == 1 && m1.macros[0].trigger == .r3 && m1.macros[0].mode == .once
        && m1.macros[0].steps == [[.a], [.a], [.lb, .a], [], [.b]], "a button and its steps")
require(macros(["macro1-button": "r3"]).macros.isEmpty && macros(["macro1-steps": "a"]).macros.isEmpty, "a button with no steps, or steps with no button, is no macro")
require(macros(["macro1-button": "start", "macro1-steps": "a"]).macros.isEmpty, "only the main ten can start a macro")
require(macros(["macro1-button": "r3", "macro1-steps": "-, -"]).macros.isEmpty, "steps that press nothing are no macro")
require(macros(["macro2-button": "l3", "macro2-steps": "x", "macro2-mode": "repeat"]).macros[0].mode == .repeating
        && macros(["macro2-button": "l3", "macro2-steps": "x", "macro2-mode": "hold"]).macros[0].mode == .hold
        && macros(["macro2-button": "l3", "macro2-steps": "x", "macro2-mode": "wat"]).macros[0].mode == .once, "three modes, anything else is once")
require(macros(["macro1-button": "r3", "macro1-steps": "a", "macro3-button": "l3", "macro3-steps": "b"]).macros.map(\.trigger) == [.r3, .l3], "slots one and three")
require(macros(["macro-step": "10"]).stepMillis == 20 && macros(["macro-step": "9999"]).stepMillis == 500 && macros([:]).stepMillis == 60, "the step time is kept in range")
require(macros(["macro1-button": "r3", "macro1-steps": "a", "macro-step": "100"]).macros[0].stepMillis == 100, "... and reaches the macro")
require(BCDMacroSettings.parseSteps("a, nope, b") == [[.a], [.b]], "a step with an unknown name is dropped")
require(BCDMacroSettings.parseSteps("a+nope, b") == [[.b]], "... a chord with one is dropped whole")
require(BCDMacroSettings.parseSteps("a+a+b") == [[.a, .b]], "a name twice in a chord is one")
require(BCDMacroSettings.parseSteps((1...30).map { _ in "a" }.joined(separator: ",")).count == 12, "no more than twelve steps")
require(BCDMacroSettings.parseSteps("A; B\nLB+X") == [[.a], [.b], [.lb, .x]], "any case, comma, semicolon or new line between steps")
let text = BCDMacroSettings.stepsText([[.a], [], [.lb, .x]])
require(text == "a, -, lb+x" && BCDMacroSettings.parseSteps(text) == [[.a], [], [.lb, .x]], "stepsText reads back")
require(BCDMacroSettings.lineNames.count == 10 && Set(BCDMacroSettings.lineNames).count == 10, "ten lines")

// ---- macros: playing -------------------------------------------------------------------------------------
var tapMacro = BCDMacro(trigger: .r3, mode: .once, steps: [[.a], [.a], [.b]], stepMillis: 50)
require(tapMacro.total == 300, "three steps of 50 ms and 50 ms between them")
require(tapMacro.output(at: 0).holds(.a) && tapMacro.output(at: 49).holds(.a) && tapMacro.output(at: 50).isEmpty && tapMacro.output(at: 99).isEmpty,
        "the first step is pressed for the step time, then let go")
require(tapMacro.output(at: 100).holds(.a) && tapMacro.output(at: 200).holds(.b) && tapMacro.output(at: 250).isEmpty && tapMacro.output(at: 300).isEmpty,
        "... the second and third in their turn, and nothing after the end")
require(tapMacro.output(at: -1).isEmpty, "nothing before the start")
var player = BCDMacroPlayer()
var idle = BCDPadBits()
var r = player.process([tapMacro], raw: idle, now: 0)
require(r.swallowed == [.r3] && r.add.isEmpty && !r.active, "idle: the button is the macro's, nothing plays")
var pressed = BCDPadBits(); pressed.press(.r3)
r = player.process([tapMacro], raw: pressed, now: 1000)
require(r.add.holds(.a) && r.active, "pressed: the first step starts at once")
r = player.process([tapMacro], raw: pressed, now: 1060)
require(r.add.isEmpty && r.active, "... held: the run goes on by itself")
r = player.process([tapMacro], raw: idle, now: 1110)
require(r.add.holds(.a) && r.active, "... released: it plays to the end")
r = player.process([tapMacro], raw: idle, now: 1210)
require(r.add.holds(.b), "... third step")
r = player.process([tapMacro], raw: idle, now: 1300)
require(r.add.isEmpty && !r.active, "... and stops")
r = player.process([tapMacro], raw: pressed, now: 1310)
require(r.add.holds(.a), "pressed again: a new run")
r = player.process([tapMacro], raw: pressed, now: 1700)
require(r.add.isEmpty && !r.active, "a button still held after the end does not start another")
r = player.process([tapMacro], raw: idle, now: 1710)
r = player.process([tapMacro], raw: pressed, now: 1720)
require(r.add.holds(.a), "... until it is let go and pressed again")
r = player.process([tapMacro], raw: pressed, now: 1750)
var pressedAgain = pressed
r = player.process([tapMacro], raw: pressedAgain, now: 1760)
require(r.active, "pressing during a run changes nothing")
pressedAgain = idle
_ = player.process([tapMacro], raw: pressedAgain, now: 1770)

var loopMacro = BCDMacro(trigger: .l3, mode: .repeating, steps: [[.x]], stepMillis: 40)
var lp = BCDMacroPlayer()
var l3 = BCDPadBits(); l3.press(.l3)
var rr = lp.process([loopMacro], raw: l3, now: 0)
require(rr.add.holds(.x) && rr.active, "repeat: pressed, the step plays")
rr = lp.process([loopMacro], raw: l3, now: 40)
require(rr.add.isEmpty, "... the gap")
rr = lp.process([loopMacro], raw: l3, now: 80)
require(rr.add.holds(.x), "... and again")
rr = lp.process([loopMacro], raw: BCDPadBits(), now: 85)
require(rr.add.isEmpty && !rr.active, "... released: it stops at once")
rr = lp.process([loopMacro], raw: l3, now: 500)
require(rr.add.holds(.x), "... pressed later: it starts from the first step")

var holdMacro = BCDMacro(trigger: .r3, mode: .hold, steps: [[.l3], [.lb]], stepMillis: 50)
var hp = BCDMacroPlayer()
var r3 = BCDPadBits(); r3.press(.r3)
var hr = hp.process([holdMacro], raw: BCDPadBits(), now: 0)
require(hr.add.isEmpty, "hold: nothing before the press")
hr = hp.process([holdMacro], raw: r3, now: 10)
require(hr.add.holds(.l3) && hr.add.holds(.lb) && hr.swallowed == [.r3], "... a press holds every input of the steps")
hr = hp.process([holdMacro], raw: BCDPadBits(), now: 20)
require(hr.add.holds(.l3), "... and keeps holding after the button is let go")
hr = hp.process([holdMacro], raw: r3, now: 30)
require(hr.add.isEmpty, "... the next press lets them go")
hr = hp.process([holdMacro], raw: BCDPadBits(), now: 40)
hr = hp.process([holdMacro], raw: r3, now: 50)
require(hr.add.holds(.l3), "... and the one after holds them again")
hp.reset()
hr = hp.process([holdMacro], raw: BCDPadBits(), now: 60)
require(hr.add.isEmpty, "reset forgets a hold")

// ---- everything in one pass -----------------------------------------------------------------------------
var extras = BCDPadExtras()
require(!extras.needsSample && !extras.configured, "nothing configured: the hook has no work")
extras.configure(turbo: turbo(["turbo": "a"]), macros: macros(["macro1-button": "r3", "macro1-steps": "b, b", "macro-step": "50"]))
require(extras.needsSample && extras.configured, "configured: the hook has work")
var x = BCDPadBits(); x.press(.a); x.press(.r3); x.press(.y)
var more = extras.process(&x, now: 0)
require(x.holds(.a) && x.holds(.b) && x.holds(.y) && !x.holds(.r3) && more, "turbo A, macro on R3 plays B, Y untouched, R3 not seen by the game")
x = BCDPadBits(); x.press(.a); x.press(.r3)
more = extras.process(&x, now: 70)
require(!x.holds(.a) && !x.holds(.b) && !x.holds(.r3) && more, "later: A in its up half, the macro in its gap")
extras.inject({ var b = BCDPadBits(); b.press(.x); return b }(), now: 100, millis: 70)
x = BCDPadBits()
more = extras.process(&x, now: 110)
require(x.holds(.x) && more, "an injected press is added")
x = BCDPadBits()
more = extras.process(&x, now: 171)
require(!x.holds(.x), "... and ends on time")
extras.reset()
extras.configure(turbo: BCDTurboSettings(), macros: BCDMacroSettings())
x = BCDPadBits(); x.press(.a); x.press(.r3)
more = extras.process(&x, now: 5000)
require(x.holds(.a) && x.holds(.r3) && !more && !extras.needsSample, "cleared: the state passes untouched, no work")
var plain = BCDPadExtras()
x = BCDPadBits(); x.buttons = 0xFFFF; x.lt = 12; x.rt = 255
let before = x
more = plain.process(&x, now: 99)
require(x == before && !more, "a default engine changes nothing")
extras.configure(turbo: turbo(["turbo": "a"]), macros: macros([:]))
var held = BCDPadBits(); held.press(.a)
_ = extras.process(&held, now: 0)
extras.configure(turbo: turbo(["turbo": "a"]), macros: macros([:]))
held = BCDPadBits(); held.press(.a)
_ = extras.process(&held, now: 60)
require(!held.holds(.a), "the same settings again keep the clock running")
extras.configure(turbo: turbo(["turbo": "a", "turbo-rate": "5"]), macros: macros([:]))
held = BCDPadBits(); held.press(.a)
_ = extras.process(&held, now: 70)
require(held.holds(.a), "other settings start the clock again")

// ---- turbo on a touch control's key or mouse button ------------------------------------------------------
var kt = BCDKeyTurbo()
require(!kt.isActive, "idle")
kt.press(.key(0x20), now: 0)
require(kt.isActive && kt.tick(now: 10, rate: 10).isEmpty, "a key goes down with the finger and stays down for half a period")
var ops = kt.tick(now: 50, rate: 10)
require(ops == [BCDKeyTurbo.Op(target: .key(0x20), down: false)], "... then comes up")
require(kt.tick(now: 60, rate: 10).isEmpty, "... once")
ops = kt.tick(now: 100, rate: 10)
require(ops == [BCDKeyTurbo.Op(target: .key(0x20), down: true)], "... and goes down again at the next period")
require(kt.release(.key(0x20)), "lifting while it is down: the game must see it come up")
require(!kt.isActive, "... and nothing is left")
kt.press(.mouseLeft, now: 1000)
_ = kt.tick(now: 1050, rate: 10)
require(!kt.release(.mouseLeft), "lifting while it is up: nothing more to send")
require(kt.release(.mouseRight), "a release of something it never held passes on")
kt.press(.mouseLeft, now: 0)
kt.press(.mouseLeft, now: 5)
require(!kt.release(.mouseLeft) && kt.isActive, "two fingers on one target: the first lift keeps it")
require(kt.release(.mouseLeft) && !kt.isActive, "... the second lets it go")
kt.press(.key(0x45), now: 0)
kt.press(.mouseRight, now: 0)
_ = kt.tick(now: 50, rate: 10)
var all = kt.releaseAll()
require(all.isEmpty && !kt.isActive, "ending the session with every target up: nothing to send")
kt.press(.key(0x45), now: 0)
kt.press(.mouseRight, now: 0)
all = kt.releaseAll()
require(all.count == 2 && all.allSatisfy { !$0.down } && !kt.isActive, "ending the session lifts what is down")

if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("ALL PASS")
