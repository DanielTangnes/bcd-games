#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""env.MADEIRA_THERMAL_CAP: an opt-in frame cap while the device is hot (ProMotionIntent.swift, ThermalPacing).

With env.MADEIRA_THERMAL_CAP = 1 (off by default, and off in BCD as in the project it came from): when iOS reports the thermal
state serious or critical, a session paced at the 60 cap, MAX or RAW drops to 40 FPS (30 where 40 is not offered) and goes back
to its own mode at nominal, unless the cap was changed by hand in between (the HUD pill and the in-game menu count). Not saved.
A hot device clocks its CPU down, and at the 60 cap a frame that misses 16.7 ms waits for the next vblank and shows at 33.3 ms.

  1. the production ThermalPacing class is compiled on the host with stand-ins for the display (the vsync mode, the 40 and 30
     caps, ProMotionIntent.apply), the log and the config, and the thermal state; the notification is posted for real:
       - switch off: nothing is observed, whatever the state;
       - on: serious -> 40 (critical too), nominal -> the session's mode comes back, each logged once;
       - on, no 40 cap: 30; neither: kept, logged;
       - the mode is already a cap (30, 40) or anything but 60/MAX/RAW: kept;
       - a cap chosen by hand (userChose, or a mode that is no longer the one it set): never replaced or restored;
       - begin() twice, end(): one observer at a time, nothing left behind;
  2. the source: Library starts and ends it with the session, the library's setFPS, the HUD pill and the in-game menu's
     FrameLimit tell it a cap was chosen, and no list and no rule turns it on.
Needs python3 and swiftc (--require-swift makes its absence a failure).
"""
import argparse
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
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + str(detail)) if detail and not cond else ""))
    ok = ok and bool(cond)


pm = (APP / "ProMotionIntent.swift").read_text()
a = pm.index("final class ThermalPacing {")
cls = pm[a:pm.index("\n}\n", a) + 3]
swiftc = shutil.which("xcrun") and ["xcrun", "swiftc"] or (shutil.which("swiftc") and ["swiftc"])
if not swiftc:
    check("swiftc is here for the Swift part", not args.require_swift)
else:
    cls_test = cls.replace("ProcessInfo.processInfo.thermalState", "fakeThermal")
    harness = '''import Foundation
nonisolated(unsafe) var fakeThermal: ProcessInfo.ThermalState = .nominal
nonisolated(unsafe) var vsync: Int32 = 1
nonisolated(unsafe) var sets: [Int32] = []
nonisolated(unsafe) var applied: [Int32] = []
nonisolated(unsafe) var logs: [String] = []
nonisolated(unsafe) var switchOn = true
nonisolated(unsafe) var has40 = true
nonisolated(unsafe) var has30 = true
func madeira_get_vsync_locked() -> Int32 { vsync }
func madeira_set_vsync_locked(_ m: Int32) { vsync = m; sets.append(m) }
enum ProMotionIntent {
    static var has40Cap: Bool { has40 }
    static var has30Cap: Bool { has30 }
    static func apply(mode: Int32) { applied.append(mode) }
}
final class LogStore { static let shared = LogStore(); func log(_ s: String) { logs.append(s) } }
enum MadeiraConfig { static func flag(_ name: String, fallback: Bool = true) -> Bool { name == "MADEIRA_THERMAL_CAP" ? switchOn : fallback } }
''' + cls_test + '''
var failed = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failed += 1 } }
func reset(mode: Int32 = 1, thermal: ProcessInfo.ThermalState = .nominal) {
    ThermalPacing.shared.end(); sets = []; applied = []; logs = []; vsync = mode; fakeThermal = thermal; has40 = true; has30 = true; switchOn = true
}
func post(_ state: ProcessInfo.ThermalState) {
    fakeThermal = state
    NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

reset(); switchOn = false
ThermalPacing.shared.begin(); post(.serious)
check(sets.isEmpty && logs.isEmpty, "switch off: nothing is observed, nothing set, nothing logged")

reset(mode: 1)
ThermalPacing.shared.begin()
check(sets.isEmpty && logs.count == 1 && logs[0].hasPrefix("[thermal-cap] on"), "on and nominal: one line, no change")
post(.serious)
check(sets == [4] && applied == [4] && vsync == 4, "serious at the 60 cap: the 40 cap")
post(.critical)
check(sets == [4], "still hot: nothing more")
post(.nominal)
check(sets == [4, 1] && applied == [4, 1] && vsync == 1, "nominal: the session's mode comes back")
post(.serious)
check(sets == [4, 1, 4], "hot again: capped again")
ThermalPacing.shared.end()
post(.nominal)
check(sets == [4, 1, 4], "end(): nothing is observed any more (the cap stays until the session's own end resets pacing)")

reset(mode: 0)
ThermalPacing.shared.begin(); post(.critical)
check(sets == [4], "MAX (0) is capped too, and critical counts")
post(.nominal)
check(vsync == 0, "  and comes back to MAX")

reset(mode: 2)
ThermalPacing.shared.begin(); post(.serious)
check(sets == [4], "RAW (2) is capped too"); post(.nominal); check(vsync == 2, "  and comes back to RAW")

reset(mode: 1); has40 = false
ThermalPacing.shared.begin(); post(.serious)
check(sets == [3], "no 40 cap: the 30 cap")

reset(mode: 1); has40 = false; has30 = false
ThermalPacing.shared.begin(); post(.serious)
check(sets.isEmpty && logs.contains { $0.contains("is kept") }, "no lower cap offered: kept, and said so")

for m in [Int32(3), Int32(4)] {
    reset(mode: m)
    ThermalPacing.shared.begin(); post(.serious)
    check(sets.isEmpty, "already capped (\\(m)): kept")
}

reset(mode: 1)
ThermalPacing.shared.begin(); post(.serious)
ThermalPacing.shared.userChose(); vsync = 2
post(.nominal)
check(sets == [4], "a cap chosen by hand after the thermal cap: never restored over it")
post(.serious)
check(sets == [4, 4] && vsync == 4, "  a later hot spell caps the person's 60/MAX/RAW again (the hand-chosen mode is only never put back over)")

reset(mode: 1)
ThermalPacing.shared.begin(); post(.serious)
vsync = 0   // changed by something else (no userChose call): the mode is no longer the one it set
post(.nominal)
check(sets == [4] && vsync == 0, "a mode that is no longer the one it set is never restored over")

reset(mode: 1)
ThermalPacing.shared.begin(); ThermalPacing.shared.begin(); post(.serious)
check(sets == [4], "begin() twice leaves one observer")

exit(failed == 0 ? 0 : 1)
'''
    with tempfile.TemporaryDirectory(prefix="thermal-cap-") as tmp:
        t = Path(tmp)
        (t / "main.swift").write_text(harness)
        b = subprocess.run(swiftc + ["-O", "-swift-version", "5", str(t / "main.swift"), "-o", str(t / "m")], capture_output=True, text=True)
        check("ThermalPacing builds on the host with stand-ins", b.returncode == 0, b.stderr[-2500:])
        if b.returncode == 0:
            r = subprocess.run([str(t / "m")], capture_output=True, text=True, timeout=120)
            for line in r.stdout.splitlines():
                print(("     " if line.startswith("ok") else "") + line)
            check("the thermal cap behaves", r.returncode == 0 and "FAIL" not in r.stdout, r.stderr[-800:])

lib = (APP / "Library.swift").read_text()
sess = (APP / "BCDSessionLive.swift").read_text()
ui = (APP / "SessionUI.swift").read_text()
check("the session starts and ends it", lib.count("ThermalPacing.shared.begin()") == 1 and lib.count("ThermalPacing.shared.end()") == 1)
check("setFPS, the HUD pill and the in-game menu's limit tell it a cap was chosen",
      "ThermalPacing.shared.userChose()\n        let applied = ProMotionIntent.supportedMode(mode)" in lib
      and "ThermalPacing.shared.userChose()   // env.MADEIRA_THERMAL_CAP" in sess and "ThermalPacing.shared.userChose()   // env.MADEIRA_THERMAL_CAP" in ui)
check("begin() does nothing without the switch", "guard Self.enabled else { return }" in cls)
text = (R / "recommended/recommendations.json").read_text() + (R / "build/tools/autotune_rules.py").read_text()
check("no recommended list and no auto-tune rule turns it on", "MADEIRA_THERMAL_CAP" not in text)

print("PASS: thermal cap" if ok else "FAIL: thermal cap")
sys.exit(0 if ok else 1)
