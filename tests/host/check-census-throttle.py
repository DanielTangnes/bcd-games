#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""DXMT's memory census is throttled for every session (ContentView.swift; env.DXMT_CENSUS_THROTTLE = 0 undoes it).

In a 64-bit game DXMT's memory census (the [mem-census] lines of a log) reported from the encode thread four to nine times a
second: a third of a log, with its top-N scans on the frame path. DXMT throttles it to one report every 10 s only in its
32-bit build by default; the app now sets DXMT_CENSUS_THROTTLE=1 for a session unless bcd.cfg, the game's own file (exported
later, so it wins) or the process environment sets it. A memory warning is never throttled and the first report of the process
is always written (dxmt_mem_census.cpp), so a run that dies early or under memory pressure still leaves its numbers. Nothing the
game sees changes; the numbers in a log come ten seconds apart. The source checks:
  - the app sets the variable without overwriting (setenv overwrite 0), only when neither bcd.cfg nor the environment names it;
  - it is set in the session setup that builds DXMT's options, before the game's own env.* lines are exported;
  - when the DXMT sources are checked out, the switch is the one DXMT reads, and a warning is exempt.
"""
from pathlib import Path
import sys

R = Path(__file__).resolve().parents[2]
cv = (R / "app/Madeira/ContentView.swift").read_text()
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + str(detail)) if detail and not cond else ""))
    ok = ok and bool(cond)


line = 'if MadeiraConfig.get("env.DXMT_CENSUS_THROTTLE") == nil && getenv("DXMT_CENSUS_THROTTLE") == nil {\n                setenv("DXMT_CENSUS_THROTTLE", "1", 0)\n            }'
check("the app sets DXMT_CENSUS_THROTTLE=1 without overwriting, unless bcd.cfg or the environment names it", line in cv)
check("  once", cv.count('"DXMT_CENSUS_THROTTLE"') == 2)
check("  among DXMT's options, before the game's own options", cv.index(line) < cv.index("madeira-bcd: the game's options from BCDLaunch.applyExtras") and
      cv.index('dxgi.customDeviceId=2544') < cv.index(line))
src = R / "dxmt/src/dxmt/dxmt_mem_census.cpp"
if src.is_file():
    t = src.read_text()
    check("DXMT reads the switch, never throttles a memory warning, and always writes the first report",
          'madeiraSwitch("DXMT_CENSUS_THROTTLE")' in t and "memory warning: always reported" in t and "if (prev && now - prev < kPeriodNs)" in t)
else:
    print("note the DXMT sources are not checked out here: the DXMT side is not read")
print("PASS: census throttle" if ok else "FAIL: census throttle")
sys.exit(0 if ok else 1)
