// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-bcd-radial.py. That script compiles this file as main.swift together with
// app/Madeira/BCDKeyNames.swift, BCDExtraKeys.swift, BCDTurbo.swift, BCDInputActions.swift and BCDRadial.swift (plain Foundation and
// CoreGraphics) and runs it: the names of the things BCD can do for a game (a key, a combination, a click, the wheel, BCD's menu, a
// button of the controller), the radial menu's settings, where its button and ring go, which slot a finger is over, and what one
// finger's touch does.
import CoreGraphics
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

// ---- actions -------------------------------------------------------------------------------------------------
func action(_ id: String) -> BCDInputAction? { BCDInputAction.parse(id) }
require(action("esc") == .key(0x1B) && action(" F5 ") == .key(0x74) && action("A") == .key(0x41) && action("7") == .key(0x37), "keys by name, any case")
require(action("alt+tab") == .chord([0x12], 0x09) && action("Ctrl+S") == .chord([0x11], 0x53), "combinations")
require(action("ctrl+alt+del") == .chord([0x11, 0x12], 0x2E) && action("alt+ctrl+del") == .chord([0x12, 0x11], 0x2E), "two modifiers, in the order given")
require(action("ctrl+ctrl+s") == .chord([0x11], 0x53), "a modifier twice is one")
require(action("alt+alt") == nil && action("alt+") == nil && action("+tab") == nil && action("tab+alt") == nil && action("foo+tab") == nil && action("alt+foo") == nil, "a combination needs modifiers and a key")
require(action("a+b+c+d+e") == nil, "no more than three modifiers and a key")
require(action("mouse-left") == .click(.left) && action("mouse-right") == .click(.right) && action("mouse-middle") == .click(.middle) && action("mouse-x") == nil, "clicks")
require(action("wheel-up") == .wheel(1) && action("wheel-down") == .wheel(-1) && action("wheel") == nil, "the wheel")
require(action("menu") == .menu && action("keyboard") == .keyboard && action("keybar") == .keyBar, "BCD's own")
require(action("pad-y") == .pad(.y) && action("pad-start") == .pad(.start) && action("pad-up") == .pad(.up) && action("pad-nope") == nil && action("pad-") == nil, "controller buttons")
require(action("") == nil && action("   ") == nil && action("nonsense") == nil && action("none") == nil, "anything else is nothing")
for choice in BCDInputAction.choices {
    let parsed = action(choice.id)
    require(parsed != nil && parsed!.id == choice.id && !choice.title.isEmpty && !choice.group.isEmpty, "choice \(choice.id): reads back, has a title and a group")
}
require(Set(BCDInputAction.choices.map(\.id)).count == BCDInputAction.choices.count, "no choice twice")
require(BCDInputAction.choices.count == 19 + 12 + 26 + 10 + 9 + 5 + 3 + 16, "the list: 19 keys, 12 function keys, 26 letters, 10 numbers, 9 combinations, 5 mouse, 3 BCD, 16 controller")
require(Array(Set(BCDInputAction.choices.map(\.group))).count == 8, "eight groups")
require(BCDInputAction.choices.first?.group == "Keys" && BCDInputAction.choices.last?.group == "Controller", "in the order they are shown")
require(action("esc")!.title == "Esc" && action("alt+tab")!.title == "Alt+Tab" && action("ctrl+alt+del")!.title == "Ctrl+Alt+Delete" && action("mouse-right")!.title == "Right click"
        && action("pad-lb")!.title == "Controller LB" && action("wheel-down")!.title == "Wheel down" && action("keybar")!.title == "Key bar", "titles")
require(action("esc")!.cap == "Esc" && action("up")!.cap == "↑" && action("alt+tab")!.cap == "A+Tab" && action("mouse-left")!.cap == "LMB" && action("menu")!.cap == "Menu" && action("pad-y")!.cap == "Y", "key caps")
require(action("space")!.keySteps == BCDExtraKeys.steps(.tap(0x20)) && action("alt+tab")!.keySteps == BCDExtraKeys.steps(.chord([0x12], 0x09)), "a key or combination goes out as the key bar's steps")
require(action("menu")!.keySteps == nil && action("mouse-left")!.keySteps == nil, "the rest has none")
let click = action("mouse-right")!.mouseSteps!
require(click.count == 2 && click[0].delay == 0 && click[0].flags == 0x8 && click[1].delay == BCDExtraKeys.tapHold && click[1].flags == 0x10, "a right click: down, then up after the tap time")
require(action("mouse-left")!.mouseSteps!.map(\.flags) == [0x2, 0x4] && action("mouse-middle")!.mouseSteps!.map(\.flags) == [0x20, 0x40], "left and middle")
require(action("wheel-up")!.mouseSteps!.map(\.data) == [120] && action("wheel-down")!.mouseSteps!.map(\.data) == [-120] && action("wheel-up")!.mouseSteps![0].flags == 0x800, "a notch of the wheel")
require(action("esc")!.mouseSteps == nil, "a key has no mouse steps")

// ---- the radial menu's settings ----------------------------------------------------------------------------------
func radial(_ lines: [String: String]) -> BCDRadialSettings { BCDRadialSettings.parse { lines[$0] } }
require(!radial([:]).isOn && radial([:]).place == .rightLow, "no lines: off, the button low on the right")
require(radial([:]).slots.map { $0?.id ?? "" } == ["esc", "tab", "enter", "space", "i", "m", "f5", "f9"], "... with the default eight slots")
require(radial([:]).slots.count == 8 && BCDRadialSettings.defaultSlots.allSatisfy { $0 != nil }, "eight slots, all with something")
require(radial(["radial": "1"]).isOn && !radial(["radial": "0"]).isOn && !radial(["radial": "on"]).isOn, "radial: only 1")
let custom = radial(["radial-1": "f1", "radial-3": "none", "radial-8": "alt+tab", "radial-5": "garbage"])
require(custom.slots[0] == .key(0x70) && custom.slots[2] == nil && custom.slots[7] == .chord([0x12], 0x09), "a slot's own action, none for empty, a combination")
require(custom.slots[4] == BCDRadialSettings.defaultSlots[4] && custom.slots[1] == BCDRadialSettings.defaultSlots[1], "a name this build does not know, or no line, is the default slot")
require(custom.filled.map(\.position) == [0, 1, 3, 4, 5, 6, 7], "filled slots keep their places on the ring")
require(radial(["radial-place": "left"]).place == .leftMiddle && radial(["radial-place": "left-top"]).place == .leftHigh && radial(["radial-place": "x"]).place == .rightLow, "places")
require(BCDRadialSettings.Place.allCases.count == 6 && Set(BCDRadialSettings.Place.allCases.map(\.rawValue)).count == 6, "six places")
require(BCDRadialSettings.Place.allCases.allSatisfy { !$0.title.isEmpty && (0...1).contains($0.height) }, "each with words and a height in range")
require(BCDRadialSettings.Place.rightLow.onRight && !BCDRadialSettings.Place.leftHigh.onRight, "right and left")
require(BCDRadialSettings.lineNames.count == 10 && Set(BCDRadialSettings.lineNames).count == 10, "ten lines")

// ---- geometry ----------------------------------------------------------------------------------------------------------
let phone = CGSize(width: 852, height: 393), pad = CGSize(width: 1194, height: 834)
let noInsets = (left: CGFloat(0), right: CGFloat(0), top: CGFloat(0), bottom: CGFloat(0))
let notch = (left: CGFloat(59), right: CGFloat(59), top: CGFloat(0), bottom: CGFloat(21))
require(BCDRadialGeometry.radius(screen: phone) == 94 && BCDRadialGeometry.radius(screen: pad) == 118, "a roomier ring on an iPad")
let right = BCDRadialGeometry.handleCenter(.rightLow, screen: phone, insets: notch), left = BCDRadialGeometry.handleCenter(.leftLow, screen: phone, insets: notch)
require(right.x > phone.width / 2 && left.x < phone.width / 2, "the button is on its side")
require(right.x + 27 <= phone.width - 59 && left.x - 27 >= 59, "... inside the safe area")
require(right.y > phone.height / 2 && BCDRadialGeometry.handleCenter(.rightHigh, screen: phone, insets: notch).y < phone.height / 2, "low and high")
require(abs(BCDRadialGeometry.handleCenter(.rightMiddle, screen: phone, insets: noInsets).y - (27 + (phone.height - 54) * 0.5)) < 0.5, "the middle is the middle of the room there is")
for place in BCDRadialSettings.Place.allCases {
    for screen in [phone, pad, CGSize(width: 390, height: 844), CGSize(width: 667, height: 375)] {
        let handle = BCDRadialGeometry.handleCenter(place, screen: screen, insets: notch)
        let r = BCDRadialGeometry.radius(screen: screen)
        let ring = BCDRadialGeometry.ringCenter(handle: handle, screen: screen, radius: r, insets: notch)
        var inside = true
        for position in 0..<8 {
            let c = BCDRadialGeometry.slotCenter(position: position, ring: ring, radius: r)
            let h = BCDRadialGeometry.slot / 2
            if c.x - h < notch.left - 0.01 || c.x + h > screen.width - notch.right + 0.01 || c.y - h < notch.top - 0.01 || c.y + h > screen.height - notch.bottom + 0.01 { inside = false }
        }
        require(inside, "\(place.rawValue.isEmpty ? "right-low" : place.rawValue) on \(Int(screen.width))x\(Int(screen.height)): every slot is on the screen")
    }
}
let ring0 = CGPoint(x: 400, y: 200)
require(BCDRadialGeometry.slotCenter(position: 0, ring: ring0, radius: 94) == CGPoint(x: 400, y: 106), "slot 0 is straight up")
let two = BCDRadialGeometry.slotCenter(position: 2, ring: ring0, radius: 94)
require(abs(two.x - 494) < 0.001 && abs(two.y - 200) < 0.001, "slot 2 is to the right")
let four = BCDRadialGeometry.slotCenter(position: 4, ring: ring0, radius: 94)
require(abs(four.x - 400) < 0.001 && abs(four.y - 294) < 0.001, "slot 4 is down")
for position in 0..<8 {
    let at = BCDRadialGeometry.slotCenter(position: position, ring: ring0, radius: 94)
    require(BCDRadialGeometry.position(of: at, ring: ring0, radius: 94) == position, "a finger on slot \(position) is over slot \(position)")
}
require(BCDRadialGeometry.position(of: CGPoint(x: 401, y: 201), ring: ring0, radius: 94) == nil, "at the centre: no slot")
require(BCDRadialGeometry.position(of: CGPoint(x: 400 + 30, y: 200), ring: ring0, radius: 94) == nil && BCDRadialGeometry.position(of: CGPoint(x: 400 + 40, y: 200), ring: ring0, radius: 94) == 2, "the centre is a dead zone of 0.38 of the radius")
require(BCDRadialGeometry.position(of: CGPoint(x: 400 + 300, y: 200), ring: ring0, radius: 94) == nil && BCDRadialGeometry.position(of: CGPoint(x: 400 + 200, y: 200), ring: ring0, radius: 94) == 2, "far out: none, within reach: the slot")
require(BCDRadialGeometry.position(of: CGPoint(x: 400 + 50, y: 200 - 50), ring: ring0, radius: 94) == 1, "up and right: slot 1")
require(BCDRadialGeometry.position(of: CGPoint(x: 400 - 50, y: 200 - 50), ring: ring0, radius: 94) == 7, "up and left: slot 7")
require(BCDRadialGeometry.position(of: CGPoint(x: 400 + 25, y: 200 - 72), ring: ring0, radius: 94) == 0, "just right of up is still up (the sectors are 45° wide)")

// ---- what a touch does -------------------------------------------------------------------------------------------------
let all = Set(0..<8)
var t = BCDRadialTouch()
require(t.began(at: CGPoint(x: 10, y: 10), onHandle: false, position: nil, filled: all) == .none && !t.isOpen, "a touch elsewhere does nothing while the ring is closed")
require(t.ended(filled: all) == .none, "... and nothing when it lifts")
// A slide: down on the button, to a slot, up.
require(t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all) == .open && t.isOpen && t.highlighted == nil, "a finger on the button opens the ring")
t.moved(to: CGPoint(x: 105, y: 100), position: 2, filled: all)
require(t.highlighted == nil, "... a finger that has hardly moved is not choosing")
t.moved(to: CGPoint(x: 160, y: 100), position: 2, filled: all)
require(t.highlighted == 2, "... one that has moved is over a slot")
t.moved(to: CGPoint(x: 160, y: 140), position: 3, filled: all)
require(t.highlighted == 3, "... and over the next")
require(t.ended(filled: all) == .choose(3) && !t.isOpen && t.highlighted == nil, "lifting over a slot chooses it and closes the ring")
// A slide to nowhere.
_ = t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all)
t.moved(to: CGPoint(x: 160, y: 100), position: nil, filled: all)
require(t.ended(filled: all) == .close && !t.isOpen, "lifting over no slot closes the ring and chooses nothing")
// A slot with nothing in it.
_ = t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: [0, 1])
t.moved(to: CGPoint(x: 160, y: 100), position: 5, filled: [0, 1])
require(t.highlighted == nil && t.ended(filled: [0, 1]) == .close, "an empty slot is not a choice")
// A tap: the ring stays for a second tap.
require(t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all) == .open, "a tap on the button")
require(t.ended(filled: all) == .none && t.isOpen && t.sticky, "... lifting at once leaves the ring open")
require(t.began(at: CGPoint(x: 200, y: 100), onHandle: false, position: 1, filled: all) == .none && t.highlighted == 1, "a touch on a slot while it waits lights it")
require(t.ended(filled: all) == .choose(1) && !t.isOpen && !t.sticky, "... and lifting chooses it")
_ = t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all)
_ = t.ended(filled: all)
_ = t.began(at: CGPoint(x: 5, y: 5), onHandle: false, position: nil, filled: all)
require(t.ended(filled: all) == .close && !t.isOpen, "a tap anywhere else closes the ring")
_ = t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all)
_ = t.ended(filled: all)
_ = t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all)
require(t.ended(filled: all) == .close, "a tap on the button again closes it")
// Cancelled.
_ = t.began(at: CGPoint(x: 100, y: 100), onHandle: true, position: nil, filled: all)
t.moved(to: CGPoint(x: 160, y: 100), position: 2, filled: all)
t.cancelled()
require(!t.isOpen && t.highlighted == nil && t.ended(filled: all) == .none, "taken away: closed, nothing chosen")
require(BCDRadialTouch.sample(open: true, highlighted: 2).isOpen && BCDRadialTouch.sample(open: true, highlighted: 2).highlighted == 2 && !BCDRadialTouch.sample(open: false, highlighted: 2).isOpen, "the preview's samples")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASS")
