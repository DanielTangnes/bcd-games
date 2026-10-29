#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Every source file of the app is compiled by the Xcode project.

Build 623's first full run stopped at "Archive (unsigned)": app/Madeira/ExternalGamesPicker.swift was in the folder (so the
whole-app `swiftc -typecheck` over `find app/Madeira -name '*.swift'` passed) but not in app/Madeira.xcodeproj, and
EntitlementChecker.swift could not find its type. This check fails at once instead: every .swift/.m/.mm/.c file under
app/Madeira must have a "<name> in Sources" build file in the project (by its path inside app/Madeira or by its file name).
"""
import pathlib
import re
import sys

R = pathlib.Path(__file__).resolve().parents[2]
app = R / "app/Madeira"
pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
built = set(re.findall(r"/\* (.+?) in Sources \*/", pbx))

missing = []
for f in sorted(app.rglob("*")):
    if f.suffix not in (".swift", ".m", ".mm", ".c"):
        continue
    rel = str(f.relative_to(app))
    if rel not in built and f.name not in built:
        missing.append(rel)

if missing:
    for m in missing:
        print("FAIL app/Madeira/%s is not built by app/Madeira.xcodeproj (add a PBXBuildFile, a file reference, the group "
              "child and the Sources entry, as for BCDGPUCardsLive.swift)" % m)
    sys.exit(1)
print("ok   %d app sources, each built by the Xcode project" % len(built))
print("PASS: Xcode project sources")
