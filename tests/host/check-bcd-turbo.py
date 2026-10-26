#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Turbo and macros (round 604): a held button repeats, a button of the controller plays a chain of presses.

Per game, off until its player turns them on (the game page's Turbo and macros, the in-game menu's Controls › Turbo and
macros). Turbo repeats a controller button while it is held (the on-screen controller's or a paired one's) and, on the touch
controls, a mouse button or a few keys; a macro makes a button play its steps once, again and again while held, or held down
until it is pressed again. The rules are plain values (BCDTurbo.swift); BCDTurboLive.swift puts the result into the
controller's state (GamepadInput) and the touch controls' key events (BCDTouchLive).

Source checks (every host):
  1. BCD's licence header on the new files, the harness and this check.
  2. Layers: BCDTurbo.swift, BCDKeyNames.swift and BCDInputPrefs.swift are Foundation only and name no engine type; the page,
     profile and menu files are plain values too; only the two Live files are engine-bound; the Xcode project builds all of them.
  3. Off means nothing: the two flags the hooks read start false and are true only while turbo or a macro is set; a timer exists
     only in the two functions that start one and stops when its work is done; nothing animates or polls.
  4. The choices live with the game's path in the app's own preferences, not in its config file.
  5. The hooks in the older files are exactly one gated line each (GamepadInput, BCDTouchLive); the game page and the in-game
     menu have the section; CI runs this check.
Behaviour (swiftc on the host; --require-swift makes its absence a failure): tests/host/bcd_turbo_checks.swift.
Build (xcrun; --require-swift makes a missing Xcode a failure): the preview build compiles with the plain files.

  check-bcd-turbo.py [--require-swift] [--skip-preview]
"""
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
ap = argparse.ArgumentParser()
ap.add_argument("--require-swift", action="store_true")
ap.add_argument("--skip-preview", action="store_true")
args = ap.parse_args()
failures = 0


def check(cond, what, detail=""):
    global failures
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[-2500:]) if detail and not cond else ""))
    if not cond:
        failures += 1


def code(text):
    out = []
    for line in text.splitlines():
        if line.strip().startswith("//"):
            continue
        out.append(re.sub(r'\s//[^"]*$', "", line))
    return "\n".join(out)


def func(text, header):
    p = text.index(header)
    a = text.index("{", p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == "{") - (text[b] == "}")
        b += 1
    return text[p:b]


HEADER = ("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)\n"
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.\n")
PLAIN = ["BCDTurbo.swift", "BCDKeyNames.swift", "BCDInputPrefs.swift"]
VIEWS = ["BCDInputProfile.swift", "BCDInputPage.swift", "BCDInputMenu.swift"]
LIVE = ["BCDTurboLive.swift", "BCDInputLive.swift"]
src = {n: (APP / n).read_text() for n in PLAIN + VIEWS + LIVE}
harness = (R / "tests/host/bcd_turbo_checks.swift").read_text()
gamepad = (APP / "GamepadInput.swift").read_text()
touch = (APP / "BCDTouchLive.swift").read_text()
session = (APP / "BCDSessionLive.swift").read_text()
page = (APP / "BCDGamePageLive.swift").read_text()
project = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
tool = (R / "tools/ui-preview.py").read_text()

# ---- 1. licence ---------------------------------------------------------------------------------
for name, text in list(src.items()) + [("bcd_turbo_checks.swift", harness)]:
    check(text.startswith(HEADER), f"{name}: BCD's licence header")
check(Path(__file__).read_text().startswith("#!/usr/bin/env python3\n# SPDX-License-Identifier: GPL-3.0-only\n# Copyright 2026 thebcd69 (BCD)\n"),
      "this check: BCD's licence header")

# ---- 2. layers ----------------------------------------------------------------------------------
ENGINE = ("CMMotionManager", "UIKit", "SwiftUI", "GamepadInput", "HardwareInput", "LibraryModel", "MadeiraConfig", "GameProfile",
          "winios_", "LogStore", "LibraryEntry", "DispatchSource")
for name in PLAIN:
    text = code(src[name])
    check(re.findall(r"^import (\w+)", text, re.M) == ["Foundation"], f"{name} imports Foundation only")
    named = sorted(w for w in ENGINE if w in text)
    check(not named, f"{name} names no engine type", ", ".join(named))
for name in VIEWS:
    text = code(src[name])
    named = sorted(w for w in ("GamepadInput", "HardwareInput", "LibraryModel", "MadeiraConfig", "GameProfile", "winios_", "LogStore", "LibraryEntry",
                               "UserDefaults") if w in text)
    check(re.findall(r"^import (\w+)", text, re.M) == ["Foundation"], f"{name} imports Foundation only")
    check(not named, f"{name} names no engine or storage type", ", ".join(named))
for name in LIVE:
    check(re.search(r'ENGINE_BOUND\s*\|=\s*\{[^}]*"%s"' % re.escape(name), tool) is not None, f"{name} is in ui-preview.py's ENGINE_BOUND")
for name in PLAIN + VIEWS:
    check(not re.search(r'ENGINE_BOUND[^\n]*"%s"' % re.escape(name), tool), f"{name} stays in the preview build")
for name in PLAIN + VIEWS + LIVE:
    check(project.count(f"/* {name} in Sources */") == 2 and project.count(f"path = {name};") == 1, f"{name} is built by the Xcode project")

# ---- 3. off means nothing ---------------------------------------------------------------------------
live = code(src["BCDTurboLive.swift"])
check("static var padNeeded = false" in live and "static var touchNeeded = false" in live, "the two flags the hooks read start false")
configure = func(live, "@MainActor func configure(")
check("Self.padNeeded = configured" in configure and "Self.touchNeeded = turbo.touchOn" in configure,
      "... and follow what is set (BCDPadExtras.needsSample, the touch controls' keys and mouse)")
check("static func now()" in live and "uptimeNanoseconds" in live, "time comes from a clock that does not jump")
set_timer = func(live, "private func setTimer(")
check(live.count("makeTimerSource") == 2, "a timer is made in exactly two places (the controller's and the touch controls')")
check("makeTimerSource" in set_timer and "if on, timer == nil" in set_timer and "source.cancel()" in set_timer and "timer = nil" in set_timer,
      "the controller's timer starts only when asked and is cancelled when its work is done")
check("setTimer(again)" in func(live, "func padSample(") and "if !work { Self.padNeeded = false }" in func(live, "func padSample("),
      "the sample hook asks for the timer from what the engine says, and turns itself off when nothing is set")
check("startTouchTimer()" in func(live, "@MainActor func passes(") and "stopTouchTimer()" in func(live, "@MainActor func passes("),
      "the touch controls' timer runs only while a finger holds a repeating key or button")
check("stopTouchTimer()" in func(live, "@MainActor func releaseKeys("), "... and stops when the keys are let go")
for word in ("Timer.scheduled", "CADisplayLink", "withAnimation", ".animation(", "TimelineView", "repeatForever"):
    check(word not in live and word not in code(src["BCDTurbo.swift"]), f"nothing runs on its own: no {word}")
check("DispatchTime" not in code(src["BCDTurbo.swift"]) and "Date()" not in code(src["BCDTurbo.swift"]), "the rules read no clock: the caller passes `now`")

# ---- 4. where the choices live --------------------------------------------------------------------------
il = code(src["BCDInputLive.swift"])
check("BCDInputPrefs.shared" in il and "GameProfile" not in il and "MadeiraConfig" not in il, "the choices are in the app's preferences, not the game's config file")
check('private static let prefix = "bcd.input."' in code(src["BCDInputPrefs.swift"]), "... under bcd.input.<feature>, by the game's path")

# ---- 5. the hooks ---------------------------------------------------------------------------------------
check("if i == 0, BCDTurboLive.padNeeded, active, keyboardMouse == nil, !LibraryController.shared.ownsInput {\n                BCDTurboLive.shared.padSample(&state)\n            }" in gamepad,
      "GamepadInput: one hook, gated on the flag, not in keyboard-and-mouse mode nor under the library's menu")
check(code(gamepad).count("BCDTurbo") == 2, "... naming the turbo twice (flag and call)", code(gamepad).count("BCDTurbo"))
check(gamepad.index("BCDGyroLive.shared.padSample(&state)") < gamepad.index("BCDTurboLive.shared.padSample(&state)") < gamepad.index("publishHID(state, live: hidLive, pad: pad)"),
      "... after the touch merge and the gyro, before the HID report is built")
check("func inputExtrasChanged() { queue.async { [self] in sample() } }" in gamepad, "... and a way to ask for another sample")
check("if BCDTurboLive.touchNeeded, !BCDTurboLive.shared.passes(event) { return }" in func(touch, "func send(_ event: BCDTouchEvent)"),
      "BCDTouchLive.send: one hook, gated on the flag")
check(session.count(".modifier(BCDInputSessionHook())") == 1, "the session view has the input hook, once")
check("out += BCDInputMenuLive.sections(model.activeEntry)" in session, "the in-game menu's Controls tab has the sections")
check("if BCDInputMenu.handles(row) { return BCDInputMenuLive.change(row, on ? \"1\" : \"0\", entry: model.activeEntry) }" in func(session, "func toggle(_ row: String, _ on: Bool)")
      and "if BCDInputMenu.handles(row) { return BCDInputMenuLive.change(row, value, entry: model.activeEntry) }" in func(session, "func choose(_ row: String, _ value: String)")
      and "if BCDInputMenu.handles(id) { return BCDInputMenuLive.page(id, model.activeEntry) }" in func(session, "func page(_ id: String)"),
      "... and answers its switches, choices and pages first")
check("if !desktop { d.groups += inputGroups(entry) }" in page and "if inputSet(setting, to: value, for: game) { return }" in page,
      "the game page has the sections (not for the Wine desktop) and takes their changes")
check("let name = String(setting.dropFirst(turboToggle.count))" in src["BCDInputProfile.swift"] and "static func handles(" in src["BCDInputProfile.swift"],
      "a setting is looked at before any game entry is looked up")
ci = R / ".github/workflows/build-ipa.yml"
if ci.exists():
    check("python3 tests/host/check-bcd-turbo.py" in ci.read_text(), "CI runs this check")

# ---- behaviour -------------------------------------------------------------------------------------------
SWIFTC = shutil.which("swiftc")
if not SWIFTC:
    check(not args.require_swift, "swiftc for the behaviour checks", "not found")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-turbo-") as tmp:
        main = Path(tmp) / "main.swift"
        main.write_text(harness)
        exe = Path(tmp) / "check"
        r = subprocess.run([SWIFTC, "-O"] + [str(APP / n) for n in PLAIN] + [str(main), "-o", str(exe)], capture_output=True, text=True)
        check(r.returncode == 0, "the behaviour checks compile on the host", r.stderr or r.stdout)
        if r.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            for line in r.stdout.splitlines():
                if line.startswith("FAIL") or line.startswith("ALL"):
                    print("  " + line)
            check(r.returncode == 0, "turbo and macros behave as described", r.stdout + r.stderr)

# ---- build -----------------------------------------------------------------------------------------------
if args.skip_preview:
    print("SKIP: the preview build (--skip-preview)")
elif not shutil.which("xcrun"):
    check(not args.require_swift, "xcrun for the preview build", "not found")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-turbo-preview-") as tmp:
        r = subprocess.run([sys.executable, str(R / "tools/ui-preview.py"), "--build-only", "--out", tmp], capture_output=True, text=True)
        check(r.returncode == 0, "the preview build compiles (the plain files without the engine)", r.stderr or r.stdout)

if failures:
    print(f"{failures} FAILED")
    sys.exit(1)
print("PASS: turbo and macros")
