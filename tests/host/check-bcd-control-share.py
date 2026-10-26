#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Shareable control layouts (round 604, C11): a layout as a small file, a file as a new layout.

Behaviour (swiftc; --require-swift makes its absence a failure): app/Madeira/BCDControlShareCore.swift compiled with
tests/host/bcd_control_share_checks.swift: a good file, the export read back, every refusal (not JSON, no marker, a newer format, no controls,
more than 120, over 256 KB, a bad position, scale, action, text, nesting), fresh ids, names (safe, unique, 40 characters), file names.

Source (every host):
  1. What comes in is data: the live side reads a copy the picker made, checks the size before it reads, parses with the core, decodes with the
     app's own decoder, and removes the copy; it opens no address, runs nothing, writes only into the layout list.
  2. An import never replaces a layout and never puts controls on screen; ControlPresetsModel.importLayout refuses a name that is taken.
  3. Sharing offers only the player's own layouts (a built-in is in every build), through the system's share sheet, and removes its temporary file.
  4. The Settings rows exist only where layouts do (MADEIRA_CONTROL_PRESETS), and CI runs this check.

  check-bcd-control-share.py [--require-swift]
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
args = ap.parse_args()
failures = 0


def check(cond, what, detail=""):
    global failures
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)) if detail and not cond else ""))
    if not cond:
        failures += 1


def code(text):
    return "\n".join(re.sub(r'\s//[^"]*$', "", l) for l in text.splitlines() if not l.strip().startswith("//"))


def block(text, header):
    p = text.index(header)
    a = text.index("{", p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == "{") - (text[b] == "}")
        b += 1
    return text[p:b]


HEADER = ("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)\n"
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.\n")
core_text = (APP / "BCDControlShareCore.swift").read_text()
live_text = (APP / "BCDControlShareLive.swift").read_text()
core, live = code(core_text), code(live_text)
presets = code((APP / "TouchControlPresets.swift").read_text())
sections = (APP / "BCDSettingsSections.swift").read_text()
settings_live = (APP / "BCDSettingsLive.swift").read_text()
pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
workflow = (R / ".github/workflows/build-ipa.yml").read_text()
preview = (R / "tools/ui-preview.py").read_text()

check(core_text.startswith(HEADER) and live_text.startswith(HEADER), "BCD's licence header on both files")
check(re.findall(r"^import (\w+)", core, re.M) == ["Foundation"] and not re.search(r"\b(TouchControl|LogStore|UIKit|UserDefaults|URLSession)\b", core),
      "the core knows Foundation only and names no engine type")
for f in ("BCDControlShareCore.swift", "BCDControlShareLive.swift"):
    check(pbx.count(f"/* {f} in Sources */") == 2 and pbx.count(f"path = {f};") == 1, f"the Xcode project builds {f}")
check(re.search(r'ENGINE_BOUND \|= \{[^}]*"BCDControlShareLive.swift"', preview) is not None, "the preview app leaves the live side out")
check("python3 tests/host/check-bcd-control-share.py" in workflow, "CI runs this check")

picked = block(live, "fileprivate static func picked(_ url: URL) {")
check(picked.index("resourceValues(forKeys: [.fileSizeKey])") < picked.index("Data(contentsOf: url"), "the size is checked before the bytes are read")
check("try? FileManager.default.removeItem(at: url)" in picked, "the picker's copy is removed after it is read")
check("asCopy: true" in live, "the picker hands over a copy, never the original")
finish = block(live, "private static func finishImport(_ data: Data?) {")
check(finish.index("BCDControlShare.parse(data)") < finish.index("JSONDecoder().decode([TouchControl].self"), "the envelope is checked, then the app's decoder reads the controls")
check("BCDControlShare.importName(parsed.name, taken: presets.store.all.map(\\.name))" in finish, "the name is made unique against the built-ins and the player's layouts")
check(not re.search(r"URLSession|URL\(string|openURL|UIApplication\.shared\.open|Process\(|dlopen|system\(", live), "nothing is fetched, opened or run")
check(not re.search(r"\.load\(|TouchControlsModel|\.controls =", live), "an import never puts controls on screen")
imp = block(presets, "@discardableResult func importLayout(name: String, controls: [TouchControl]) -> String? {")
check("store.named(name) == nil" in imp and "case .created(let id) = s.save(" in imp and "persist()" in imp, "the model adds a new layout only (a taken name is refused; replaced would not match .created)")
share = block(live, "static func share(layoutID: String) {")
check("!ControlPresetStore.isBuiltIn(preset.id)" in share and "completionWithItemsHandler" in share and "removeItem(at: url)" in share,
      "sharing offers the player's own layouts and removes its temporary file")
check("BCDControlShare.export(name: preset.name, game: nil" in share, "the export carries the layout's name and no player or device detail")
check("var canShareLayouts: Bool { false }" in sections and "if backend.canShareLayouts {" in sections and "var canShareLayouts: Bool { ControlPresetsModel.enabled }" in settings_live,
      "the Settings rows exist where layouts do")

swiftc = shutil.which("swiftc")
if not swiftc:
    check(not args.require_swift, "swiftc on the host (behaviour checks)")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-control-share-") as t:
        exe = Path(t) / "run"
        b = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-o", str(exe), str(APP / "BCDControlShareCore.swift"),
                            str(R / "tests/host/bcd_control_share_checks.swift")], capture_output=True, text=True)
        check(b.returncode == 0, "the core and its checks compile on the host", b.stderr[-1500:])
        if b.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
            oks = [l for l in r.stdout.splitlines() if l.startswith("ok")]
            bad = [l for l in r.stdout.splitlines() if l.startswith("FAIL") or l.startswith("     ")]
            check(r.returncode == 0 and len(oks) >= 20, f"the layout file rules: {len(oks)} checks", "\n      ".join(bad[:10]))

print("PASS: shareable control layouts" if failures == 0 else f"FAILED: shareable control layouts ({failures})")
sys.exit(1 if failures else 0)
