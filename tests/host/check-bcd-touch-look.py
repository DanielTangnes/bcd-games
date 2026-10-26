#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Touch-control look (round 604): the colour of the on-screen buttons, what a press lights up in, the symbols on the face buttons.

One choice for every game (a taste of whoever holds the device), made from the in-game menu (Controls › Touch control look,
with a sample) or the game page (Touch control look): a body (Night, Graphite, Light, Outline only), a colour when pressed (BCD
violet, blue, green, red, amber, white), how a press shows (BCD light, solid, bright ring, soft) and the symbols (Xbox letters
or the PlayStation's). BCD's own look is what a player who chooses nothing has, drawn with the values and fills the controls
always had.

Source checks (every host):
  1. BCD's licence header on the new files, the harness and this check.
  2. Layers: BCDTouchLook.swift is Foundation only; BCDTouchLookViews.swift is SwiftUI only (no engine type); both are built
     into the preview app; the Xcode project builds both.
  3. BCD's own look draws as before: every colour and fill of the standard look is BCDTouchPalette's or BCDStyle's, the press
     fill is BCDTouchPalette.pressed, and the face reads every colour through the look.
  4. Nothing costs a frame: no timer, animation, blur or shadow in the new files; a control redraws when its look changes.
  5. The choice is kept for everyone in the app's preferences (feature "touchlook"), the live controls watch one model, and
     a change reloads it.
  6. The game page and the in-game menu offer it; CI runs this check.
Behaviour (swiftc on the host; --require-swift makes its absence a failure): tests/host/bcd_touch_look_checks.swift.
Build (xcrun; --require-swift makes a missing Xcode a failure): the preview build compiles with the views.

  check-bcd-touch-look.py [--require-swift] [--skip-preview]
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


HEADER = ("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)\n"
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.\n")
look_src = (APP / "BCDTouchLook.swift").read_text()
views_src = (APP / "BCDTouchLookViews.swift").read_text()
controls = (APP / "BCDTouchControls.swift").read_text()
touch_live = (APP / "BCDTouchLive.swift").read_text()
harness = (R / "tests/host/bcd_touch_look_checks.swift").read_text()
session = (APP / "BCDSessionLive.swift").read_text()
input_live = (APP / "BCDInputLive.swift").read_text()
page = (APP / "BCDInputPage.swift").read_text()
menu = (APP / "BCDInputMenu.swift").read_text()
project = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
tool = (R / "tools/ui-preview.py").read_text()

# ---- 1. licence ---------------------------------------------------------------------------------
for name, text in (("BCDTouchLook.swift", look_src), ("BCDTouchLookViews.swift", views_src), ("bcd_touch_look_checks.swift", harness)):
    check(text.startswith(HEADER), f"{name}: BCD's licence header")
check(Path(__file__).read_text().startswith("#!/usr/bin/env python3\n# SPDX-License-Identifier: GPL-3.0-only\n# Copyright 2026 thebcd69 (BCD)\n"),
      "this check: BCD's licence header")

# ---- 2. layers ----------------------------------------------------------------------------------
look = code(look_src)
views = code(views_src)
check(re.findall(r"^import (\w+)", look, re.M) == ["Foundation"], "BCDTouchLook.swift imports Foundation only")
check(re.findall(r"^import (\w+)", views, re.M) == ["SwiftUI"], "BCDTouchLookViews.swift imports SwiftUI only")
named = sorted(w for w in ("GamepadInput", "HardwareInput", "LibraryModel", "MadeiraConfig", "GameProfile", "winios_", "LogStore", "LibraryEntry", "TouchControlsModel")
               if w in look or w in views)
check(not named, "neither names an engine type", ", ".join(named))
for name in ("BCDTouchLook.swift", "BCDTouchLookViews.swift"):
    check(not re.search(r'ENGINE_BOUND[^\n]*"%s"' % re.escape(name), tool), f"{name} is built into the preview app")
    check(project.count(f"/* {name} in Sources */") == 2 and project.count(f"path = {name};") == 1, f"{name} is built by the Xcode project")

# ---- 3. BCD's own look draws as before --------------------------------------------------------------------
check("look.bodyColors?.fill.color ?? BCDTouchPalette.fill" in views and "look.bodyColors?.rim.color ?? BCDTouchPalette.rim" in views
      and "look.bodyColors?.label.color ?? BCDTouchPalette.label" in views, "Night's fill, rim and label are BCDTouchPalette's")
check("if look.accent == .violet { return AnyShapeStyle(BCDTouchPalette.pressed(opacity)) }" in views, "BCD's light on a press is BCDTouchPalette.pressed")
check("look.accent.ends?.0.color ?? BCDStyle.violet" in views and "look.accent.ends?.1.color ?? BCDStyle.fuchsia" in views, "... and BCD violet is BCDStyle's violet and fuchsia")
check("return BCDTouchPalette.face(name)" in views, "the Xbox face colours are the palette's")
face = controls[controls.index("struct BCDTouchFace: View"):controls.index("/// A mouse with its left or right button filled.")]
check("BCDTouchPalette." not in code(face).replace("BCDTouchPalette.selected", ""), "the face draws every colour through the look (only the editor's selection ring is the palette's)")
check("BCDTouchPalette.selected" in code(face), "... which stays BCD's whatever the look")
check("paint.fill.opacity(paint.fillStrength * opacity)" in face and "paint.fill.opacity(paint.stickFillStrength * opacity)" in face, "fills use the look's strengths (0.46 and 0.36 for Night)")
check("let look: BCDTouchLook" in controls and "a.look == b.look" in controls and ".environment(\\.bcdTouchLook, look)" in controls,
      "a control is redrawn when its look changes, and hands the look to its face")
check("var look = BCDTouchLook()" in controls, "the layer's look defaults to BCD's own")

# ---- 4. nothing costs a frame ----------------------------------------------------------------------------
for word in ("Timer", "CADisplayLink", "withAnimation", ".animation(", "TimelineView", "repeatForever", ".blur(", ".shadow(", "Material", "UIBlurEffect"):
    check(word not in look and word not in views, f"no {word}")
check(".transaction { $0.animation = nil }" in views, "the sample never animates")

# ---- 5. where the choice lives ------------------------------------------------------------------------------
check('static let feature = "touchlook"' in views and "BCDInputPrefs.shared.lines(feature, game: BCDInputPrefs.everyone)" in views, "kept for everyone, in the app's preferences")
check('static let touchLook = "touchlook"' in (APP / "BCDInputProfile.swift").read_text()
      and "static let global: Set<String> = [touchLook, players]" in (APP / "BCDInputProfile.swift").read_text(), "... a global feature (no game's path)")
check("if write.feature == BCDInputLines.touchLook { BCDTouchLookModel.shared.reload() }" in input_live, "a change reloads the model the controls watch")
check("@ObservedObject private var looks = BCDTouchLookModel.shared" in touch_live and "look: looks.look" in touch_live, "the live controls watch the model")

# ---- 6. where a player finds it ------------------------------------------------------------------------------
check('BCDGameSettingGroup(id: "touchlook", title: "Touch control look"' in page and '"look-body"' in page and '"look-icons"' in page, "the game page has the section")
check("lookPage" in menu and "case lookPage: return lookPageContent(profile)" in menu and "kind: .custom(lookCustom)" in menu, "the in-game menu has the page, with a sample")
check("menu.custom[BCDInputMenu.lookCustom] = { AnyView(BCDTouchLookSampleLive()) }" in session, "... which the session draws")
ci = R / ".github/workflows/build-ipa.yml"
if ci.exists():
    check("python3 tests/host/check-bcd-touch-look.py" in ci.read_text(), "CI runs this check")

# ---- behaviour -------------------------------------------------------------------------------------------
SWIFTC = shutil.which("swiftc")
if not SWIFTC:
    check(not args.require_swift, "swiftc for the behaviour checks", "not found")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-look-") as tmp:
        main = Path(tmp) / "main.swift"
        main.write_text(harness)
        exe = Path(tmp) / "check"
        r = subprocess.run([SWIFTC, "-O", str(APP / "BCDTouchLook.swift"), str(main), "-o", str(exe)], capture_output=True, text=True)
        check(r.returncode == 0, "the look's behaviour checks compile on the host", r.stderr or r.stdout)
        if r.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            for line in r.stdout.splitlines():
                if line.startswith("FAIL") or line.startswith("ALL"):
                    print("  " + line)
            check(r.returncode == 0, "the look behaves as described", r.stdout + r.stderr)

# ---- build -----------------------------------------------------------------------------------------------
if args.skip_preview:
    print("SKIP: the preview build (--skip-preview)")
elif not shutil.which("xcrun"):
    check(not args.require_swift, "xcrun for the preview build", "not found")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-look-preview-") as tmp:
        r = subprocess.run([sys.executable, str(R / "tools/ui-preview.py"), "--build-only", "--out", tmp], capture_output=True, text=True)
        check(r.returncode == 0, "the preview build compiles with the look's views", r.stderr or r.stdout)

if failures:
    print(f"{failures} FAILED")
    sys.exit(1)
print("PASS: touch-control look")
