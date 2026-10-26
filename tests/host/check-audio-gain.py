#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""env.MADEIRA_AUDIO_GAIN: the game's volume at the audio endpoint (round 604, F6), and the game page's Sound rows that set it.

The driver's real code (build/ntdll-unix/audio_null_ios.c: the parser, the scaling, the once-only read of the environment, the app's setter) is cut
out of the source and compiled on the host:
  - unset, empty, "100" or anything that is not 10..200 in digits ("0", "9", "201", "50%", " 50", "-5", "abc", "99999") leaves the volume
    unchanged: a slip never mutes a game; "10".."200" scale it;
  - the scaling is exact (50 halves, 200 doubles) and 100 would change nothing;
  - the environment is read once; the setter works while the game runs and ignores values outside 10..200.
And from the sources: the render callback scales only when the value is not 1000 (default: one comparison), before its clamp (so a boost cannot
wrap); the endpoint reads the environment when it is made; the catalog lists the key; the game page's Sound rows write the game's own lines and
nothing else; CI runs this check.

  check-audio-gain.py
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("\n     " + str(detail)) if detail and not cond else ""))
    ok &= bool(cond)


src = (R / "build/ntdll-unix/audio_null_ios.c").read_text()
start = src.index("static _Atomic int g_gain_permille = 1000;")
end = src.index("static struct ios_stream *stream_from_handle(")
gain = src[start:end]
render = src[src.index("static OSStatus ios_audio_render_cb("):]
render = render[:render.index("\n}\n") + 3]
create = src[src.index("static int ios_dev_create_locked(const struct ios_stream *s)"):]
create = create[:create.index("\n}\n") + 3]

# ---- the sources -----------------------------------------------------------------------------------------------
check("the volume is per mille, 1000 by default, an atomic the render thread reads relaxed",
      "static _Atomic int g_gain_permille = 1000;" in src and "atomic_load_explicit(&g_gain_permille, memory_order_relaxed)" in render)
check("the render callback scales only when the value is not 1000, so the default is one comparison",
      "if (gain != 1000) ios_apply_gain(out, total, gain);" in render)
check("... after the clients are summed and before the clamp, so a boost cannot wrap into noise",
      render.index("ios_mix_stream(s, out, nframes, dev_ch, dev_rate)") < render.index("ios_apply_gain(out, total, gain)") < render.index("if (out[k] > 1.0f)"))
check("the endpoint reads the environment when it is made", "ios_audio_gain_init();" in create)
check("the environment is read in one place", src.count('getenv("MADEIRA_AUDIO_GAIN")') == 1)
check("the app's setter is exported and takes percent", "\nvoid madeira_audio_set_gain_percent(int percent)\n" in src)

# ---- the code ---------------------------------------------------------------------------------------------------
harness = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stddef.h>
""" + gain + r"""
static int fails;
#define EXPECT(cond, what) do { if (!(cond)) { printf("FAIL %s (line %d)\n", what, __LINE__); fails++; } } while (0)
int main(void)
{
    const char *keep[] = { NULL, "", "100", "0", "9", "201", "50%", " 50", "-5", "abc", "99999", "5x", "1e2", "0100" };
    const char *scale[] = { "10", "25", "50", "75", "150", "200" };
    int want[] = { 100, 250, 500, 750, 1500, 2000 };   /* per mille */
    size_t i;
    for (i = 0; i < sizeof(keep) / sizeof(keep[0]); i++) EXPECT(ios_audio_gain_parse(keep[i]) == 1000, keep[i] ? keep[i] : "(null)");
    for (i = 0; i < sizeof(scale) / sizeof(scale[0]); i++) EXPECT(ios_audio_gain_parse(scale[i]) == want[i], scale[i]);
    {
        float v[4] = { 0.5f, -0.5f, 0.25f, 0.0f };
        ios_apply_gain(v, 4, 500);
        EXPECT(v[0] == 0.25f && v[1] == -0.25f && v[2] == 0.125f && v[3] == 0.0f, "50 percent halves");
        ios_apply_gain(v, 4, 2000);
        EXPECT(v[0] == 0.5f && v[1] == -0.5f, "200 percent doubles");
        ios_apply_gain(v, 4, 1000);
        EXPECT(v[0] == 0.5f && v[2] == 0.25f, "1000 per mille changes nothing");
        ios_apply_gain(v, 0, 500);
        EXPECT(v[0] == 0.5f, "zero samples touch nothing");
    }
    EXPECT(atomic_load(&g_gain_permille) == 1000, "the volume starts unchanged");
    unsetenv("MADEIRA_AUDIO_GAIN");
    ios_audio_gain_init();
    EXPECT(atomic_load(&g_gain_permille) == 1000, "no environment: unchanged, and it was read");
    setenv("MADEIRA_AUDIO_GAIN", "50", 1);
    ios_audio_gain_init();
    EXPECT(atomic_load(&g_gain_permille) == 1000, "the environment is read once (a later change is not taken)");
    madeira_audio_set_gain_percent(80);
    EXPECT(atomic_load(&g_gain_permille) == 800, "the app's setter works while the game runs");
    madeira_audio_set_gain_percent(5);
    madeira_audio_set_gain_percent(250);
    madeira_audio_set_gain_percent(-1);
    EXPECT(atomic_load(&g_gain_permille) == 800, "... and ignores 5, 250 and -1");
    madeira_audio_set_gain_percent(100);
    EXPECT(atomic_load(&g_gain_permille) == 1000, "... 100 puts it back");
    if (fails) return 1;
    puts("ok");
    return 0;
}
"""
cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    check("a C compiler for the driver harness", False)
else:
    with tempfile.TemporaryDirectory() as t:
        c = Path(t) / "gain.c"
        c.write_text(harness)
        exe = Path(t) / "gain"
        b = subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-O1", "-o", str(exe), str(c)], capture_output=True, text=True)
        check("the driver's volume code compiles on the host", b.returncode == 0, b.stderr[-2000:])
        if b.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            check("the volume rules hold (unchanged unless 10..200, exact scaling, read once, the setter)", r.returncode == 0 and r.stdout.strip().endswith("ok"), r.stdout[-800:])

# ---- the catalog, the page, CI ------------------------------------------------------------------------------------
catalog = (R / "app/Madeira/ConfigCatalog.generated.swift").read_text()
check("the settings catalog lists env.MADEIRA_AUDIO_GAIN and env.MADEIRA_AUDIO_LEAD_MS", 'key: "env.MADEIRA_AUDIO_GAIN"' in catalog and 'key: "env.MADEIRA_AUDIO_LEAD_MS"' in catalog)
words = (R / "app/Madeira/BCDGameSound.swift").read_text()
live = (R / "app/Madeira/BCDGamePageLiveSound.swift").read_text()
check("the Sound rows write only the game's own lines: latency, volume, and the resume switch",
      set(re.findall(r'"(env\.MADEIRA_AUDIO_[A-Z_]+)"', words)) == {"env.MADEIRA_AUDIO_LEAD_MS", "env.MADEIRA_AUDIO_GAIN", "env.MADEIRA_AUDIO_RESUME"}
      and not re.search(r'"env\.', live))
check("a game's line changes only when it differs, and a game the library does not hold yet is saved with it",
      "if (file.get(key) ?? \"\") != (line ?? \"\") { file.set(key, line) }" in live and "LibraryModel.shared.save(entry)" in live)
hooks = (R / "app/Madeira/BCDGamePageLive.swift").read_text()
check("the page has the two hooks: the rows join the Sound section, and the setting", hooks.count("soundSettings(entry)") == 1 and hooks.count("soundSet(setting, to: value, for: game)") == 1)
pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
for f in ("BCDGameSound.swift", "BCDGamePageLiveSound.swift"):
    check(f"the Xcode project builds {f}", pbx.count(f"/* {f} in Sources */") == 2 and pbx.count(f"path = {f};") == 1)
page = (R / "app/Madeira/BCDGamePage.swift").read_text()
with tempfile.TemporaryDirectory() as t:
    t = Path(t)
    (t / "Rules.swift").write_text("import Combine\nimport Foundation\nimport SwiftUI\n\n" + page[page.index("// MARK: - The page's rules"):page.index("// MARK: - Opening the page")])
    for n in ("BCDStore.swift", "BCDGameDLC.swift", "BCDGameSound.swift"):
        shutil.copy(R / "app/Madeira" / n, t / n)
    shutil.copy(R / "tests/host/bcd_sound_checks.swift", t / "Harness.swift")
    b = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-o", str(t / "snd")] + sorted(str(p) for p in t.glob("*.swift")), capture_output=True, text=True)
    check("the Sound rows compile with the page's rules", b.returncode == 0, b.stderr[-1500:])
    if b.returncode == 0:
        r = subprocess.run([str(t / "snd")], capture_output=True, text=True, timeout=60)
        bad = [l for l in r.stdout.splitlines() if l.startswith("FAIL") or l.startswith("     ")]
        check("the Sound rows hold (defaults write nothing, choices are the driver's, hand-typed values stay)", r.returncode == 0, "\n".join(bad[:8]))
wf = (R / ".github/workflows/build-ipa.yml").read_text()
check("CI runs this check", "run: python3 tests/host/check-audio-gain.py" in wf)
print("PASS: audio gain" if ok else "FAILED: audio gain")
sys.exit(0 if ok else 1)
