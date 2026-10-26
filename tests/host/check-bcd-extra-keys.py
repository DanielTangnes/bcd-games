#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The extra keys (round 603): a floating key bar over the game and a second page on the bar over the iOS keyboard.

Alt+Tab, Alt+Enter, Win, F1 to F12, Esc, Del, Ins, Home, End, Page Up and Down, Space, the arrows, and Ctrl, Alt and
Shift as latches (a tap holds one for the next key, a long press locks it). Opened from the in-game menu (Game › Key
bar) and from the keyboard bar's "Fn" key; they go out through winios_post_key like every other key of the app.

Source checks (every host):
  1. BCD's licence header on every file of the feature, the harness and this check.
  2. Layers: BCDExtraKeys.swift is Foundation only (rules and values, no engine or UI type); BCDExtraKeyBar.swift
     is SwiftUI only (no engine type); only BCDExtraKeysLive.swift posts keys, and tools/ui-preview.py leaves it out
     of the preview build; the Xcode project builds all three.
  3. The keyboard bar's first page is exactly what it was (Esc, Ctrl, Shift, Alt, Tab, Enter and the arrows, posted by
     the code it always used) with one new key, "Fn", that turns to the second page and sends nothing; only the second
     page's own keys go out through the extra keys, and its Ctrl, Shift and Alt are the first page's latches.
  4. Both in-game menus (a library session's and the touch-controls window's) have the Key bar row, and the key bar's
     window is made only then: nothing exists, polls or animates while it is closed.
  5. CI runs this check.
Behaviour (swiftc on the host; --require-swift makes its absence a failure): tests/host/bcd_extra_keys_checks.swift.
Build (xcrun; --require-swift makes a missing Xcode a failure): the preview build compiles with the feature's views.

  check-bcd-extra-keys.py [--require-swift] [--skip-preview]
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
    """The text without comments, so a word in a comment counts for nothing."""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        out.append(re.sub(r'\s//[^"]*$', "", line))
    return "\n".join(out)


HEADER = ("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)\n"
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.\n")
FILES = ["BCDExtraKeys.swift", "BCDExtraKeyBar.swift", "BCDExtraKeysLive.swift"]
src = {n: (APP / n).read_text() for n in FILES}
harness = (R / "tests/host/bcd_extra_keys_checks.swift").read_text()
session = (APP / "BCDSession.swift").read_text()
live_session = (APP / "BCDSessionLive.swift").read_text()
project = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
tool = (R / "tools/ui-preview.py").read_text()

# ---- 1. licence ---------------------------------------------------------------------------------
for name, text in list(src.items()) + [("bcd_extra_keys_checks.swift", harness)]:
    check(text.startswith(HEADER), f"{name}: BCD's licence header")
check(Path(__file__).read_text().startswith("#!/usr/bin/env python3\n# SPDX-License-Identifier: GPL-3.0-only\n# Copyright 2026 thebcd69 (BCD)\n"),
      "this check: BCD's licence header")

preview_keys = (R / "app/BCDPreview/BCDPreviewExtraKeys.swift").read_text()
preview_app = (R / "app/BCDPreview/BCDPreviewApp.swift").read_text()
check(preview_keys.startswith(HEADER), "BCDPreviewExtraKeys.swift: BCD's licence header")
check(".modifier(BCDPreviewExtraKeysScreens(store: store))" in preview_app and 'hasPrefix("keybar")' in preview_keys,
      "the preview app shows -BCDTab keybar, keybar-held and keybar-fn")

# ---- 2. layers ----------------------------------------------------------------------------------
keys = code(src["BCDExtraKeys.swift"])
bar = code(src["BCDExtraKeyBar.swift"])
live = code(src["BCDExtraKeysLive.swift"])
check(re.findall(r"^import (\w+)", keys, re.M) == ["Foundation"], "BCDExtraKeys.swift imports Foundation only")
check(re.findall(r"^import (\w+)", bar, re.M) == ["SwiftUI"], "BCDExtraKeyBar.swift imports SwiftUI only")
ENGINE = ["LibraryModel", "LibraryKeyboard", "LibraryController", "TouchControlsModel", "GamepadInput", "HardwareInput",
          "MetalBackedView", "LogStore", "MadeiraConfig", "winios_", "madeira_", "wine_", "UIKit", "UIApplication"]
for name, body in (("BCDExtraKeys.swift", keys), ("BCDExtraKeyBar.swift", bar)):
    named = sorted({w for w in ENGINE if re.search(r"\b" + re.escape(w) if not w.endswith("_") else re.escape(w), body)})
    check(not named, f"{name} names no engine or UIKit type", ", ".join(named))
posters = [n for n in FILES if "winios_post_key" in code(src[n])]
check(posters == ["BCDExtraKeysLive.swift"], "only BCDExtraKeysLive.swift posts keys (winios_post_key)", posters)
check("winios_post_key" not in code(session), "BCDSession.swift (the views) still posts nothing")
check(re.search(r'ENGINE_BOUND\s*\|=\s*\{[^}]*"BCDExtraKeysLive\.swift"', tool) is not None,
      "BCDExtraKeysLive.swift is in ui-preview.py's ENGINE_BOUND")
check(not re.search(r'ENGINE_BOUND[^\n]*"BCDExtraKey(s|Bar)\.swift"', tool), "the two plain files stay in the preview build")
for name in FILES:
    check(project.count(f"/* {name} in Sources */") == 2 and project.count(f"path = {name};") == 1,
          f"{name} is built by the Xcode project")

# ---- 3. the keyboard bar --------------------------------------------------------------------------
first = re.search(r"static let all: \[BCDKeyboardKey\] = \[(.*?)\n    \]", session, re.S)
check(first is not None, "BCDKeyboardKey.all is found")
if first:
    ids = [i.strip('"') for i in re.findall(r'\.init\(id: ("?[\w.]+"?)', first.group(1))]
    # A key another feature adds in front (the clipboard's "paste", round 603) is not this check's business.
    ids = [i for i in ids if i != "paste"]
    check(ids == ["esc", "ctrl", "shift", "alt", "tab", "enter", "left", "up", "down", "right"],
          "the keyboard bar's first page: its ten keys exactly as before (a paste key in front is another feature's)", ids)
check("static let more: [BCDKeyboardKey] = BCDExtraKeys.keyboardPage.map { .init(id: $0.id, title: $0.title, latches: $0.isModifier) }" in session,
      "the second page is BCDExtraKeys.keyboardPage, its modifiers latching")
check("model.secondPage ? BCDKeyboardKey.more : BCDKeyboardKey.all" in session, "the bar shows the page the model says")
check("Button { model.secondPage.toggle() } label: {" in session and 'Text(model.secondPage ? "\u2039 Keys" : "Fn \u203a")' in session.replace("‹", "\u2039").replace("›", "\u203a"),
      "a key of its own beside Done (Fn, then Keys) turns the page and sends nothing")
accessory = live_session[live_session.index("@MainActor enum BCDKeyboardAccessory"):live_session.index("final class BCDHostedBar")]
check('private static let codes: [String: Int32] = ["esc": 0x1B, "ctrl": 0x11, "shift": 0x10, "alt": 0x12, "tab": 0x09, "enter": 0x0D,\n'
      '                                                 "left": 0x25, "up": 0x26, "down": 0x28, "right": 0x27]' in accessory,
      "the first page's key codes are unchanged")
check("}, done: { LibraryKeyboard.hide() }, extra: { [weak input] key in" in accessory
      and "guard let input, let extra = BCDExtraKeys.key(key.id), !extra.isModifier else { return }\n            BCDKeySender.send(extra.action, held: input.held)" in accessory,
      "a key of the second page goes out through the extra keys, with the latches' modifiers held")
check("var extra: (BCDKeyboardKey) -> Void = { _ in }" in session
      and "Button { if model.secondPage && !key.latches { extra(key) } else { press(key) } } label: {" in session,
      "... only a key of the second page that is not a latch; the latches and the first page go through press, as before")
check(accessory.index("extra: { [weak input] key in") > accessory.index("guard let input, let vk = codes[key.id] else { return }"),
      "... and the old path above is untouched")
check("input.press(vk)" in accessory and "winios_post_key(vk, 0) } else { input.held.insert(vk); winios_post_key(vk, 1)" in accessory,
      "the old path (press, latches that stay down until pressed again) is unchanged")

# ---- 4. the menus and the window --------------------------------------------------------------------
check(live_session.count("BCDExtraKeysMenu.row()") == 2, "both in-game menus have the Key bar row")
check(live_session.count("case BCDExtraKeysMenu.rowID:") == 2, "... and both act on it")
check("model.menu = false" in live_session[live_session.index("case BCDExtraKeysMenu.rowID:"):][:200]
      and "BCDExtraKeysHost.shared.toggle()" in live_session[live_session.index("case BCDExtraKeysMenu.rowID:"):][:300],
      "the library menu closes, then shows or hides the bar")
check("BCDExtraKeysMenu.rowID:\n            close()" in live_session, "the touch-controls window's menu closes, then shows or hides it")
check(re.search(r"func show\(\) \{\s*guard window == nil", live) is not None, "the window is made when the bar is opened, once")
check("window = nil" in live and "w.isHidden = true" in live, "... and dropped when it closes")
check("makeKeyAndVisible" not in live, "the bar's window is never made key (the game keeps the keyboard focus)")
check("windowLevel = .normal + 103" in live, "above the keyboard window (+102) and the touch controls (+101)")
check(re.search(r"hitRect[^\n]*contains\(point\)", live) is not None and "return nil" in live[live.index("override func hitTest"):][:300],
      "the window takes a touch only where the bar is")
check("releaseAll()" in live and "willResignActiveNotification" in live, "the latches are let go when the bar closes and when the app leaves")
check("LibraryModel.shared.current" in live and "library.menu" in live, "the bar goes with a library session and steps aside for the menu")
for word in ("Timer", "CADisplayLink", "withAnimation", ".animation(", ".blur(", "Material", "ProgressView", "repeatForever", "TimelineView"):
    check(word not in bar and word not in live and word not in keys, f"nothing runs on its own: no {word}")

# ---- 5. CI -----------------------------------------------------------------------------------------
ci = R / ".github/workflows/build-ipa.yml"
if ci.exists():
    check("python3 tests/host/check-bcd-extra-keys.py" in ci.read_text(), "CI runs this check")

# ---- behaviour -------------------------------------------------------------------------------------
SWIFTC = shutil.which("swiftc")
if not SWIFTC:
    check(not args.require_swift, "swiftc for the behaviour checks", "not found")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-extra-keys-") as tmp:
        main = Path(tmp) / "main.swift"
        main.write_text(harness)
        exe = Path(tmp) / "check"
        r = subprocess.run([SWIFTC, "-O", str(APP / "BCDExtraKeys.swift"), str(main), "-o", str(exe)], capture_output=True, text=True)
        check(r.returncode == 0, "the behaviour checks compile on the host", r.stderr or r.stdout)
        if r.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            for line in r.stdout.splitlines():
                if line.startswith("FAIL") or line.startswith("ALL"):
                    print("  " + line)
            check(r.returncode == 0, "the extra keys press what they should", r.stdout + r.stderr)

# ---- build -----------------------------------------------------------------------------------------
if args.skip_preview:
    print("SKIP: the preview build (--skip-preview)")
elif not shutil.which("xcrun"):
    check(not args.require_swift, "xcrun for the preview build", "not found")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-extra-keys-preview-") as tmp:
        r = subprocess.run([sys.executable, str(R / "tools/ui-preview.py"), "--build-only", "--out", tmp], capture_output=True, text=True)
        check(r.returncode == 0, "the preview build compiles (the key bar's views without the engine)", r.stderr or r.stdout)

if failures:
    print(f"{failures} FAILED")
    sys.exit(1)
print("PASS: the extra keys")
