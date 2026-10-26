#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""MIDI music (round 603): the driver side (build/ntdll-unix/bcd_midi_ios.c, bcd_midi_ios.h, the midi_* slots of audio_null_ios.c).

No Wine runs and no sound plays; tests/host/check-midi-synth.py plays the real synthesizer. Part A reads the sources and
pins the promises: off (env.MADEIRA_MIDI = 0) is exactly what every earlier build did, the 64-bit and 32-bit tables keep their 37
slots, no Wine header is included, the SoundFont is fetched and checked and never committed, its licence travels with it, and the
build and CI carry the new files. Part B compiles the driver on this Mac against a synthesizer that only records what it is told
(ASan, UBSan, and a ThreadSanitizer run) and sends it winmm's messages in mmdevapi's argument blocks, 64-bit and 32-bit (a guest
window built from a heap block): open and its notification, running status, program changes, system exclusive with prepare and
unprepare, volume, reset, close, two handles, a failing engine, the input and auxiliary counts (0, never the error code), the
notify thread's wait and its end. Part C compiles all three files for the iPhone with the warnings on.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
NT = R / "build/ntdll-unix"
HEADER = ["// SPDX-License-Identifier: GPL-3.0-only",
          "// Copyright 2026 thebcd69 (BCD)",
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md."]
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or not detail else "\n     " + str(detail)))
    ok &= bool(cond)


def read(p):
    return Path(p).read_text(encoding="utf-8")


def code(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r'"(?:[^"\\]|\\.)*"', '""', line.split("//")[0]) for line in text.split("\n"))


# ------------------------------------------------------------------------------ Part A: the sources
core, synth, header = read(NT / "bcd_midi_ios.c"), read(NT / "bcd_midi_synth_ios.m"), read(NT / "bcd_midi_ios.h")
audio = read(NT / "audio_null_ios.c")
build = read(NT / "build.sh")
for name, text in (("bcd_midi_ios.c", core), ("bcd_midi_synth_ios.m", synth), ("bcd_midi_ios.h", header),
                   ("midi_driver_host.c", read(R / "tests/host/midi_driver_host.c")), ("midi_synth_host.m", read(R / "tests/host/midi_synth_host.m")),
                   ("midi_chain_host.m", read(R / "tests/host/midi_chain_host.m"))):
    check(f"{name}: BCD's licence header, exactly", text.split("\n")[:3] == HEADER)
for name, text in (("bcd_midi_ios.c", core), ("bcd_midi_synth_ios.m", synth), ("bcd_midi_ios.h", header)):
    includes = re.findall(r'#\s*(?:include|import)\s*[<"]([^>"]+)[>"]', text)
    wine = [i for i in includes if i.split("/")[0] in ("ntstatus.h", "windef.h", "winbase.h", "winternl.h", "mmsystem.h", "mmddk.h", "wine", "winnt.h")]
    check(f"{name}: includes no Wine header (CoreFoundation and Wine's headers disagree about names)", not wine, wine)
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', text)
    check(f"{name}: no \"Madeira\" in a string it shows or logs (the env names are the one place the word stays)",
          not [x for x in literals if "madeira" in x.lower() and not re.fullmatch(r"MADEIRA_[A-Z_]+", x)
               and not x.startswith("env.MADEIRA_") and "env.MADEIRA_" not in x])

# off is what every earlier build did
check("midi_init answers DRV_SUCCESS only when bcd_midi_init says so, DRV_FAILURE (with the old log line) otherwise",
      "if (bcd_midi_init())" in audio and "IOS_DRV_SUCCESS" in audio and "midi_init -> DRV_FAILURE" in audio)
check("env.MADEIRA_MIDI = 0 and a missing sound bank both end in no device (bcd_midi_init returns 0 before it counts a load)",
      re.search(r'getenv\("MADEIRA_MIDI"\).*?strcmp\(e, "0"\) == 0', core, re.S) is not None
      and core.index("if (!midi_on())") < core.index("bcd_synth_bank_path()") < core.index("g_loaded++"))
check("the engine is built at the first open, not at init (a game that only lists devices pays nothing)",
      "bcd_synth_open(" in core[core.index("static unsigned open_device"):core.index("unsigned bcd_midi_out_open(")]
      and "bcd_synth_open(" not in core[core.index("int bcd_midi_init(void)"):core.index("static void close_synth_locked")])
check("the engine goes down with the last handle, and with the last release for a game that never closed",
      "if (g_open == 0) close_synth_locked();" in core and "if (g_loaded == 0)" in core and "close_synth_locked();" in core[core.index("void bcd_midi_release"):core.index("int bcd_midi_notify_wait")])

# the slots
def table(name):
    body = audio[audio.index("const void *%s[] = {" % name):]
    body = body[:body.index("};")]
    return re.findall(r"^\s*(\w+),\s*/\*\s*(\w+)", body, re.M)

t64, t32 = dict((s, f) for f, s in table("audio_null_ios_unix_call_funcs")), dict((s, f) for f, s in table("audio_null_ios_unix_call_wow64_funcs"))
check("the 64-bit table: init, release, out, in, wait and aux are the new functions",
      (t64["midi_init"], t64["midi_release"], t64["midi_out_message"], t64["midi_in_message"], t64["midi_notify_wait"], t64["aux_message"])
      == ("ios_midi_init", "ios_midi_release", "ios_midi_out_message", "ios_midi_in_message", "ios_midi_notify_wait", "ios_aux_message"), t64)
check("the 32-bit table: out, in and aux are the WoW64 thunks, init and wait keep theirs, release is shared (no arguments)",
      (t32["midi_init"], t32["midi_release"], t32["midi_out_message"], t32["midi_in_message"], t32["midi_notify_wait"], t32["aux_message"])
      == ("ios_wow64_midi_init", "ios_midi_release", "ios_wow64_midi_out_message", "ios_wow64_midi_in_message", "ios_wow64_midi_notify_wait", "ios_wow64_aux_message"), t32)
check("each slot calls its width's function", all(x in audio for x in (
    "bcd_midi_out_message64(args)", "bcd_midi_in_message64(args)", "bcd_midi_aux_message64(args)",
    "bcd_midi_out_message32(args)", "bcd_midi_in_message32(args)", "bcd_midi_aux_message32(args)", "bcd_midi_notify_wait(500)", "bcd_midi_release()")))
check("the old stub that answered NOT SUPPORTED to everything is gone (it made winmm count 8 devices of a kind)",
      "ios_midi_message" not in audio and "ios_aux_message_params" not in audio)
check("the notify wait never returns instantly without quit (it was a busy loop in builds before 562)",
      "int quit = bcd_midi_notify_wait(500);" in audio and "pthread_cond_timedwait" in core)

# build, packaging, licence
check("build.sh compiles both files without the Wine include paths and archives both objects",
      'bcd_midi_ios.c bcd_midi_synth_ios.m' in build and '"$OBJ_DIR/bcd_midi_ios.o" "$OBJ_DIR/bcd_midi_synth_ios.o"' in build
      and "-fobjc-arc -fmodules" in build)
fetch = read(R / "tools/fetch-soundfont.sh")
notice = read(R / "app/Madeira/soundfont/NOTICE-TimGM6mb.txt")
sha = re.search(r"^SHA256=([0-9a-f]{64})$", fetch, re.M).group(1)
check("the fetch script pins the SoundFont's SHA-256 and two sources; the notice names the same hash",
      sha in notice and fetch.count("https://") >= 2 and f"SIZE=5969788" in fetch, sha)
check("the notice gives the licence, the authors and where the file comes from", all(x in notice for x in ("GPL-2.0", "Tim Brechbill", "David Bolton", "sources.debian.org", "musescore-old")))
check("the licence text is in LICENSES and in the app's bundled legal folder", (R / "LICENSES/GPL-2.0.txt").read_text() == (R / "app/Madeira/legal/LICENSES/GPL-2.0.txt").read_text()
      and "Version 2, June 1991" in read(R / "LICENSES/GPL-2.0.txt"))
for f in ("THIRD-PARTY-NOTICES.md", "app/Madeira/legal/THIRD-PARTY-NOTICES.md"):
    t = read(R / f)
    check(f"{f}: the SoundFont is listed with its licence, hash and how it is carried", "**TimGM6mb SoundFont**" in t and sha in t and "GPL-2.0" in t and "**not** committed" in t)
check("the short notice the package ships names it too", "TimGM6mb.sf2" in read(R / "app/Madeira/licenses/THIRD-PARTY-NOTICES.txt") and sha in read(R / "app/Madeira/licenses/THIRD-PARTY-NOTICES.txt"))
check("the credits screen has a title for the licence file", '"GPL-2.0.txt": ' in read(R / "app/Madeira/BCDSettingsLive.swift"))
gitignore = read(R / ".gitignore")
check(".gitignore keeps the SoundFont out of the repository, the notice in", "app/Madeira/soundfont/*.sf2" in gitignore and (R / "app/Madeira/soundfont/.gitkeep").exists())
tracked = subprocess.run(["git", "-C", str(R), "ls-files", "--", "*.sf2", "*.sf3", "*.dls"], capture_output=True, text=True).stdout.split()
check("no SoundFont is tracked by git (CLAUDE.md: no externally supplied binaries)", not tracked, tracked)
project = read(R / "app/Madeira.xcodeproj/project.pbxproj")
check("the Xcode project carries the soundfont folder into the app's resources",
      len(re.findall(r"soundfont", project)) >= 6 and "lastKnownFileType = folder; path = soundfont" in project and "soundfont in Resources" in project)
check("the bank is looked for where the project puts it (a folder reference named soundfont, TimGM6mb.sf2)",
      'CFSTR("TimGM6mb"), CFSTR("sf2"), CFSTR("soundfont")' in synth)

# the game page's Sound section (one row: this game's MIDI music, On or Off)
APP = R / "app/Madeira"
midi_live = read(APP / "BCDMidi/BCDGamePageLiveMidi.swift")
page_live = read(APP / "BCDGamePageLive.swift")
project_text = read(R / "app/Madeira.xcodeproj/project.pbxproj")
check("BCDGamePageLiveMidi.swift: BCD's licence header, exactly", midi_live.split("\n")[:3] == HEADER)
check("it is built by the Xcode project, in a folder the preview build does not read",
      project_text.count("/* BCDMidi/BCDGamePageLiveMidi.swift in Sources */") == 2 and project_text.count("/* BCDGamePageLiveMidi.swift */") >= 3)
check("the row writes the game's own line env.MADEIRA_MIDI: absent for On (the default), 0 for Off",
      'static let midiKey = "env.MADEIRA_MIDI"' in midi_live and 'BCDGameChoice(value: "", label: "On (default)")' in midi_live
      and 'BCDGameChoice(value: "0", label: "Off")' in midi_live and "let line: String? = value.isEmpty ? nil : value" in midi_live)
check("BCDGamePageLive hands the section and its row over once each",
      page_live.count("midiGroup(entry)") == 1 and page_live.count("midiSet(setting, to: value, for: game)") == 1
      and page_live.index("midiSet(setting") < page_live.index('let on = value == "1"'))
check("the words say what it costs and that it takes effect from the next start", "17 to 30 MB" in midi_live and "next start" in midi_live)

# the switch and the catalog
gen = read(R / "build/tools/gen-config-catalog.py")
catalog = read(R / "app/Madeira/ConfigCatalog.generated.swift")
check("env.MADEIRA_MIDI is cataloged: a switch, on by default, with its words",
      '"env.MADEIRA_MIDI": {"category": "Audio", "title": "MIDI music"' in gen
      and re.search(r'ConfigOption\(key: "env.MADEIRA_MIDI", title: "MIDI music", kind: \.bool, defaultValue: "1"', catalog) is not None)
check("and so is the custom bank", 'ConfigOption(key: "env.MADEIRA_MIDI_SOUNDFONT"' in catalog)
check("the catalog is current (it is regenerated in a tree that has Wine, DXMT and FEX; this host check compares the two MIDI keys only)",
      "env.MADEIRA_MIDI\"" in catalog and "env.MADEIRA_MIDI_SOUNDFONT\"" in catalog)

workflow = read(R / ".github/workflows/build-ipa.yml")
check("CI runs the driver check, fetches the bank, runs the synthesizer check, in that order",
      0 <= workflow.find("python3 tests/host/check-midi-driver.py") < workflow.find("bash tools/fetch-soundfont.sh") < workflow.find("python3 tests/host/check-midi-synth.py"))

# the fetch script: a wrong file is never installed, a missing network is a warning not a failure
with tempfile.TemporaryDirectory(prefix="fetch-soundfont-") as tmp:
    t = Path(tmp)
    (t / "wrong.sf2").write_bytes(b"RIFF" + b"x" * 5969784)   # the right size, the wrong bytes
    env = dict(os.environ, BCD_SOUNDFONT_CACHE=str(t / "cache"), BCD_SOUNDFONT_URLS=f"file://{t}/wrong.sf2 file://{t}/missing.sf2")
    r = subprocess.run(["bash", str(R / "tools/fetch-soundfont.sh"), str(t / "dest")], capture_output=True, text=True, env=env)
    check("a file with the wrong bytes is refused and nothing is installed (exit 0, a warning)",
          r.returncode == 0 and not (t / "dest/TimGM6mb.sf2").exists() and not (t / "cache/TimGM6mb.sf2").exists() and "::warning::" in r.stdout, r.stdout + r.stderr)
    bank = R / "app/Madeira/soundfont/TimGM6mb.sf2"
    if bank.exists() and hashlib.sha256(bank.read_bytes()).hexdigest() == sha:
        env["BCD_SOUNDFONT_URLS"] = f"file://{t}/wrong.sf2 file://{bank}"
        r = subprocess.run(["bash", str(R / "tools/fetch-soundfont.sh"), str(t / "dest2")], capture_output=True, text=True, env=env)
        check("the first source is wrong, the second right: the right file is installed and cached",
              r.returncode == 0 and (t / "dest2/TimGM6mb.sf2").read_bytes() == bank.read_bytes() and (t / "cache/TimGM6mb.sf2").exists(), r.stdout + r.stderr)
        r = subprocess.run(["bash", str(R / "tools/fetch-soundfont.sh"), str(t / "dest3")], capture_output=True, text=True,
                           env=dict(os.environ, BCD_SOUNDFONT_CACHE=str(t / "cache"), BCD_SOUNDFONT_URLS="file:///nowhere"))
        check("with the cache filled no source is needed", r.returncode == 0 and (t / "dest3/TimGM6mb.sf2").exists() and "from the cache" in r.stdout, r.stdout)
    else:
        print("note: no bank at app/Madeira/soundfont/TimGM6mb.sf2 here; the good-file cases of the fetch script were not run")

# ------------------------------------------------------------------------------ Part B: the driver, compiled and run
cc = shutil.which("cc") or shutil.which("clang")
if not cc:
    check("a C compiler is here", False)
else:
    with tempfile.TemporaryDirectory(prefix="midi-driver-") as tmp:
        t = Path(tmp)
        src = [str(R / "tests/host/midi_driver_host.c"), str(NT / "bcd_midi_ios.c")]
        for label, flags in (("AddressSanitizer + UBSan", ["-fsanitize=address,undefined", "-O1", "-g"]), ("ThreadSanitizer", ["-fsanitize=thread", "-O2"])):
            exe = t / ("host-" + label.split()[0].lower())
            r = subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror"] + flags + ["-o", str(exe)] + src + ["-lpthread"], capture_output=True, text=True)
            check(f"the driver compiles on this Mac with -Wall -Wextra -Werror ({label})", r.returncode == 0, (r.stderr or r.stdout)[-2500:])
            if r.returncode:
                continue
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            lines = [l for l in r.stdout.split("\n") if l.strip()]
            print("\n".join("     " + l for l in lines if l.startswith("FAIL") or l.startswith("   ") or "checks," in l))
            check(f"the driver holds under winmm's messages, 64-bit and 32-bit ({label})", r.returncode == 0 and "0 failed" in r.stdout, (r.stdout + r.stderr)[-2500:])

# ------------------------------------------------------------------------------ Part C: for the iPhone
sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True)
if sdk.returncode:
    check("the iPhone SDK is here for the cross-compile (skipped without it)", True)
else:
    base = ["xcrun", "-sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk.stdout.strip(), "-miphoneos-version-min=17.0", "-O2", "-fPIC",
            "-fvisibility=hidden", "-fno-stack-protector", "-fno-strict-aliasing"]
    with tempfile.TemporaryDirectory(prefix="midi-ios-") as tmp:
        for name, extra in (("bcd_midi_ios.c", ["-Wall", "-Wextra", "-Werror"]), ("bcd_midi_synth_ios.m", ["-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-Werror"])):
            r = subprocess.run(base + extra + ["-c", str(NT / name), "-o", str(Path(tmp) / (name + ".o"))], capture_output=True, text=True)
            check(f"{name} compiles for the iPhone with the warnings on", r.returncode == 0, (r.stderr or r.stdout)[-2500:])
        r = subprocess.run(base + ["-Wno-implicit-function-declaration", "-Wno-int-conversion", "-c", str(NT / "audio_null_ios.c"), "-o", str(Path(tmp) / "audio.o")],
                           capture_output=True, text=True)
        check("audio_null_ios.c compiles for the iPhone with the new slots", r.returncode == 0, (r.stderr or r.stdout)[-2500:])
        if r.returncode == 0:
            undefined = subprocess.run(["nm", "-u", str(Path(tmp) / "audio.o")], capture_output=True, text=True).stdout
            defined = subprocess.run(["nm", "-g", "--defined-only", str(Path(tmp) / "bcd_midi_ios.c.o")], capture_output=True, text=True).stdout
            needed = sorted(set(re.findall(r"_(bcd_midi_\w+)", undefined)))
            check("every bcd_midi_ function audio_null_ios.c calls is defined by bcd_midi_ios.c", needed and all(f"_{n}" in defined for n in needed),
                  [n for n in needed if f"_{n}" not in defined])
            synth_defined = subprocess.run(["nm", "-g", "--defined-only", str(Path(tmp) / "bcd_midi_synth_ios.m.o")], capture_output=True, text=True).stdout
            core_undefined = subprocess.run(["nm", "-u", str(Path(tmp) / "bcd_midi_ios.c.o")], capture_output=True, text=True).stdout
            wanted = sorted(set(re.findall(r"_(bcd_synth_\w+)", core_undefined)))
            check("every bcd_synth_ function the driver calls is defined by the synthesizer", wanted and all(f"_{n}" in synth_defined for n in wanted),
                  [n for n in wanted if f"_{n}" not in synth_defined])

print("PASS: MIDI driver" if ok else "FAIL: MIDI driver")
sys.exit(0 if ok else 1)
