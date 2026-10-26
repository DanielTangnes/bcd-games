#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Radial menu (round 604): a button at the edge opens a ring of up to eight things round the thumb.

Per game, off until its player turns it on (the game page's Radial menu, the in-game menu's Controls). The slots name things BCD can do
for a game (BCDInputAction: a key, a combination such as Alt+Tab, a click, a turn of the wheel, BCD's menu, the iOS keyboard, the
key bar, a short press of a controller button); the same names bind the touch gestures. Slide to a slot and let go, or lift at once
and tap one.

Source checks (every host):
  1. BCD's licence header on the new files, the harness and this check.
  2. Layers: BCDInputActions.swift and BCDRadial.swift are plain values (Foundation, CoreGraphics), BCDRadialViews.swift is SwiftUI
     with no engine type, only BCDRadialLive.swift touches the engine and it stays out of the preview build; the Xcode project builds all.
  3. Off means nothing: no window exists until a game whose ring is on is played; it steps aside for the menu and the starting screen
     and is dropped when the game ends; no timer, polling or animation; the model publishes only what changed.
  4. Actions go out through the code every other key uses (BCDKeySender, winios_pointer, the key bar, the controller injection).
  5. The game page and the in-game menu offer it; CI runs this check.
Behaviour (swiftc on the host; --require-swift makes its absence a failure): tests/host/bcd_radial_checks.swift.
Build (xcrun; --require-swift makes a missing Xcode a failure): the preview build compiles with the ring's views.

  check-bcd-radial.py [--require-swift] [--skip-preview]
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bcd_input_kit import APP, R, Checks, code, func, imports  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--require-swift", action="store_true")
ap.add_argument("--skip-preview", action="store_true")
args = ap.parse_args()
k = Checks(args)
check = k.check

PLAIN = ["BCDInputActions.swift", "BCDRadial.swift"]
src = {n: (APP / n).read_text() for n in PLAIN + ["BCDRadialViews.swift", "BCDRadialLive.swift"]}
harness = (R / "tests/host/bcd_radial_checks.swift").read_text()
project = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
tool = (R / "tools/ui-preview.py").read_text()
input_live = (APP / "BCDInputLive.swift").read_text()
page = (APP / "BCDInputPage.swift").read_text()
menu = (APP / "BCDInputMenu.swift").read_text()
profile = (APP / "BCDInputProfile.swift").read_text()

# ---- 1. licence ---------------------------------------------------------------------------------
k.licence(list(src.items()) + [("bcd_radial_checks.swift", harness)], __file__)

# ---- 2. layers ----------------------------------------------------------------------------------
check(imports(src["BCDInputActions.swift"]) == ["Foundation"], "BCDInputActions.swift imports Foundation only")
check(sorted(imports(src["BCDRadial.swift"])) == ["CoreGraphics", "Foundation"], "BCDRadial.swift imports Foundation and CoreGraphics only")
for name in PLAIN:
    named = sorted(w for w in ("UIKit", "SwiftUI", "GamepadInput", "HardwareInput", "LibraryModel", "MadeiraConfig", "GameProfile", "winios_", "LogStore", "UserDefaults") if w in code(src[name]))
    check(not named, f"{name} names no engine, UI or storage type", ", ".join(named))
views = code(src["BCDRadialViews.swift"])
check(sorted(imports(src["BCDRadialViews.swift"])) == ["SwiftUI", "UIKit"], "BCDRadialViews.swift imports SwiftUI and UIKit only")
check(not [w for w in ("GamepadInput", "HardwareInput", "LibraryModel", "MadeiraConfig", "winios_", "LogStore") if w in views], "... and names no engine type")
check(re.search(r'ENGINE_BOUND\s*\|=\s*\{[^}]*"BCDRadialLive\.swift"', tool) is not None, "BCDRadialLive.swift is in ui-preview.py's ENGINE_BOUND")
for name in PLAIN + ["BCDRadialViews.swift"]:
    check(not re.search(r'ENGINE_BOUND[^\n]*"%s"' % re.escape(name), tool), f"{name} stays in the preview build")
for name in PLAIN + ["BCDRadialViews.swift", "BCDRadialLive.swift"]:
    check(project.count(f"/* {name} in Sources */") == 2 and project.count(f"path = {name};") == 1, f"{name} is built by the Xcode project")

# ---- 3. off means nothing ------------------------------------------------------------------------------
live = code(src["BCDRadialLive.swift"])
configure = func(live, "func configure(_ settings: BCDRadialSettings")
check("let on = settings.isOn && running" in configure and "if window == nil { show(title: title) }" in configure and "else if window != nil {\n            hide()" in configure,
      "the window is made only for a game whose ring is on and that is being played, and dropped when either stops")
check(live.count("BCDRadialWindow(windowScene:") == 1, "the window is made in one place")
hide = func(live, "private func hide()")
check("window = nil" in hide and "isHidden = true" in hide and "watchers.removeAll()" in hide, "hiding drops the window and its watchers")
check("library.menu" in live and "library.launching" in live and "model.cancel()" in func(live, "private func sessionChanged()"), "it steps aside for the menu and the starting screen")
check("willResignActiveNotification" in live, "... and lets go when the app leaves the foreground")
check("w.windowLevel = .normal + 104" in live and "isHidden = false   // never made key" in src["BCDRadialLive.swift"], "above the key bar, never the key window (the game keeps the keyboard)")
for word in ("Timer", "CADisplayLink", "withAnimation", ".animation(", "TimelineView", "repeatForever", "makeTimerSource", ".blur(", ".shadow(", "Material"):
    check(word not in live and word not in views, f"nothing runs on its own: no {word}")
check(".transaction { $0.animation = nil }" in views, "the ring never animates")
publish = func(code(src["BCDRadialViews.swift"]), "private func publish()")
check("if isOpen != touch.isOpen" in publish and "if highlighted != touch.highlighted" in publish, "the model publishes only what changed")
check("report(open ? CGRect(origin: .zero, size: geo.size) : handleFrame.insetBy(dx: -8, dy: -8))" in views, "the window takes the button's place while closed and the whole screen while open")

# ---- 4. how actions go out ---------------------------------------------------------------------------------
runner = func(live, "enum BCDInputActionRunner")
check("BCDKeySender.post(steps)" in runner and "winios_pointer(0, 0, step.flags" in runner, "keys go out as the key bar's do, clicks and the wheel as the touch controls' mouse buttons do")
check("case .menu: LibraryModel.shared.showMenu()" in runner and "case .keyboard: MetalBackedView.toggleKeyboard()" in runner
      and "case .keyBar: BCDExtraKeysHost.shared.toggle()" in runner and "case .pad(let input): BCDTurboLive.shared.inject(input)" in runner,
      "BCD's menu, the iOS keyboard, the key bar and the controller press use the code that already does them")

# ---- 5. where a player finds it ----------------------------------------------------------------------------
check("BCDRadialHost.shared.configure(profile.radial, running: entry != nil && !library.launching, title: title)" in input_live, "the session's hook tells the ring what the game chose")
check('BCDGameSettingGroup(id: "radial", title: "Radial menu"' in page and '"radial-place"' in page and '"radial-\\(n)"' in page, "the game page has the Radial menu with its place and eight slots")
check('id: "in.radial", title: "Radial menu"' in menu and "in.radial-place" in menu, "the in-game menu has it")
check("BCDRadialSettings.lineNames.contains(line) { return radial }" in profile, "its lines are routed to the radial feature")
ci = R / ".github/workflows/build-ipa.yml"
if ci.exists():
    check("python3 tests/host/check-bcd-radial.py" in ci.read_text(), "CI runs this check")

# ---- behaviour and build ------------------------------------------------------------------------------------------
k.harness("the radial menu", ["BCDKeyNames.swift", "BCDExtraKeys.swift", "BCDTurbo.swift", "BCDInputPrefs.swift", "BCDInputActions.swift", "BCDRadial.swift"], "bcd_radial_checks.swift")
k.preview("with the ring's views")
k.finish("radial menu")
