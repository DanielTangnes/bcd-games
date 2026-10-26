#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""MIDI music (round 603): the synthesizer against Apple's real AUMIDISynth and the SoundFont the app carries.

Needs a Mac and the bank (app/Madeira/soundfont/TimGM6mb.sf2, from tools/fetch-soundfont.sh, or BCD_MIDI_TEST_BANK); without
either it says so and passes (the fetch step of the build warns when the bank is missing). Renders offline, so no audio device is
used and nothing is heard:

  tests/host/midi_synth_host.m   build/ntdll-unix/bcd_midi_synth_ios.m alone: a note makes sound, the General MIDI percussion
                                 channel makes sound, a program change changes it, volume scales it, GM and GS resets are
                                 accepted, all-sound-off silences a held note, closing gives the memory back, it opens and
                                 closes again without growing, a file that is not a bank is refused;
  tests/host/midi_chain_host.m   the whole chain short of Wine: winmm's messages in mmdevapi's 64-bit argument block through
                                 bcd_midi_ios.c into the synthesizer: open, a General MIDI reset as long data, a chord by running
                                 status, drums, MODM_SETVOLUME, MODM_RESET, close.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
NT = R / "build/ntdll-unix"
SHA = "c5378b62028c920cb11e4803327983fee2f2cdff5dc89c708e39da417e51c854"
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or not detail else "\n     " + str(detail)))
    ok &= bool(cond)


if sys.platform != "darwin" or not shutil.which("xcrun"):
    print("note: not a Mac with Xcode here; the synthesizer is checked on the macOS build runner")
    print("PASS: MIDI synthesizer (skipped)")
    sys.exit(0)

bank = Path(os.environ.get("BCD_MIDI_TEST_BANK", R / "app/Madeira/soundfont/TimGM6mb.sf2"))
if not bank.exists():
    print(f"::warning::check-midi-synth: no sound bank at {bank}; run tools/fetch-soundfont.sh first. Not checked.")
    print("PASS: MIDI synthesizer (skipped: no bank)")
    sys.exit(0)
if "BCD_MIDI_TEST_BANK" not in os.environ:
    check("the bank is the one the fetch script pins", hashlib.sha256(bank.read_bytes()).hexdigest() == SHA)

frameworks = ["-framework", "AVFoundation", "-framework", "AudioToolbox", "-framework", "Foundation", "-framework", "CoreFoundation"]
with tempfile.TemporaryDirectory(prefix="midi-synth-") as tmp:
    t = Path(tmp)
    mac = ["xcrun", "--sdk", "macosx", "clang"]
    r = subprocess.run(mac + ["-fobjc-arc", "-fmodules", "-O1", "-DBCD_SYNTH_OFFLINE", "-Wall", "-Wno-unused-function"] + frameworks
                       + ["-o", str(t / "synth"), str(R / "tests/host/midi_synth_host.m")], capture_output=True, text=True)
    check("the synthesizer compiles on this Mac with its offline renderer", r.returncode == 0, (r.stderr or r.stdout)[-2500:])
    if r.returncode == 0:
        r = subprocess.run([str(t / "synth"), str(bank)], capture_output=True, text=True, timeout=600)
        print("\n".join("     " + l for l in (r.stdout).split("\n") if l.startswith("FAIL") or "memory" in l or "checks," in l))
        check("Apple's synthesizer plays the bank (notes, percussion, programs, volume, resets, memory, reopening, a bad file)",
              r.returncode == 0 and "0 failed" in r.stdout, (r.stdout + r.stderr)[-2500:])

    objs = []
    for name, extra in (("synth", ["-fobjc-arc", "-fmodules", "-DBCD_SYNTH_OFFLINE", str(NT / "bcd_midi_synth_ios.m")]),
                        ("core", [str(NT / "bcd_midi_ios.c")]),
                        ("main", ["-fobjc-arc", "-fmodules", str(R / "tests/host/midi_chain_host.m")])):
        obj = t / f"chain_{name}.o"
        r = subprocess.run(mac + ["-O1", "-Wall", "-c"] + extra + ["-o", str(obj)], capture_output=True, text=True)
        check(f"the chain test: {name} compiles", r.returncode == 0, (r.stderr or r.stdout)[-2500:])
        objs.append(str(obj))
    if len(objs) == 3 and all(Path(o).exists() for o in objs):
        r = subprocess.run(mac + ["-o", str(t / "chain")] + objs + frameworks, capture_output=True, text=True)
        check("the chain test links", r.returncode == 0, (r.stderr or r.stdout)[-2500:])
        if r.returncode == 0:
            r = subprocess.run([str(t / "chain"), str(bank)], capture_output=True, text=True, timeout=600)
            print("\n".join("     " + l for l in (r.stdout).split("\n") if l.startswith("FAIL") or "checks," in l))
            check("winmm's messages reach Apple's synthesizer and make sound, and stop when told", r.returncode == 0 and "0 failed" in r.stdout,
                  (r.stdout + r.stderr)[-2500:])

print("PASS: MIDI synthesizer" if ok else "FAIL: MIDI synthesizer")
sys.exit(0 if ok else 1)
