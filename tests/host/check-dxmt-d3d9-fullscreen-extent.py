#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""tools/patch-dxmt-fullscreen-extent.py: DXMT D3D9 accepts plausible fullscreen extents and garbage refresh rates.

Blur (logs 8XZKXY, S465J5) passes 1160x800@4199012 / 1174409890 (uninitialized stack garbage in
FullScreen_RefreshRateInHz), and The Secret of Monkey Island: Special Edition (Steam 32360, logs
0QM8ZF, FTZTQ1) passes 3456x2234@0 from a MacBook Pro Retina Settings.ini; both failed CreateDevice
with D3DERR_INVALIDCALL (0x8876086c). Checks:
  - the new isPresentableFullscreenExtent, cut out of the patch and compiled on the host:
    - enumerated adapter modes (1408x648@60, 1160x800@60, 1160x800@0) and kPresentableExtents
      (640x480@0, 1024x768@0, 1280x720@0) return true without logging or reading the environment;
    - Blur's 1160x800@4199012 and 1160x800@1174409890, Monkey Island SE's 3456x2234@0, and boundary
      extents 320x200@60 and 7680x4320@120 return true and log at most 4 "[d3d9-modes]" lines;
    - nonsense extents (0x0, 319x200, 320x199, 7681x4320, 320x4321, 99999x99999) are still rejected;
    - env.MADEIRA_D3D9_STRICT_MODES=1 restores the exact old answers across every test case;
  - on a copy of dxmt/src/d3d9/d3d9_interface.cpp (when checked out in dxmt/ or ~/madeira-bcd/dxmt):
    the patch applies cleanly and idempotently;
  - CI runs this check and the patch before the i386 farm key.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

R = pathlib.Path(__file__).resolve().parents[2]
PATCH = R / "tools/patch-dxmt-fullscreen-extent.py"
p = PATCH.read_text()
ok = True


def check(what, cond, detail=None):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or detail is None else f"  [{detail}]"))
    ok = ok and bool(cond)


new_fn = re.search(r'NEW = """(.*?)"""', p, re.S).group(1)
old_fn = re.search(r'OLD = """(.*?)"""', p, re.S).group(1)

cxx = shutil.which("c++") or shutil.which("clang++") or shutil.which("g++")
if not cxx:
    print("skip: no C++ compiler")
else:
    harness = r"""
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <string>
#include <vector>

typedef uint32_t UINT;
struct Mode { UINT width; UINT height; UINT refresh; };
static std::vector<Mode> adapterModes(UINT) {
  return {{1408, 648, 60}, {1160, 800, 60}};
}
static UINT refreshRateHzOr60(const Mode &m) { return m.refresh ? m.refresh : 60; }
static const struct { UINT width; UINT height; } kPresentableExtents[] = {
  {320, 240}, {512, 384}, {640, 400}, {640, 480}, {720, 480}, {800, 600},
  {1024, 768}, {1152, 864}, {1280, 720}, {1280, 960}, {1280, 1024},
};
static int g_env_reads = 0, g_logs = 0;
namespace env {
static std::string getEnvVar(const char *name) {
  g_env_reads++;
  const char *v = std::getenv(name);
  return v ? std::string(v) : std::string();
}
}
namespace str {
template <typename... A> std::string format(A...) { return "[d3d9-modes]"; }
}
struct Logger {
  static void warn(const std::string &) { g_logs++; }
};
""" + new_fn + "\n" + old_fn.replace("isPresentableFullscreenExtent", "isPresentableFullscreenExtent_old") + r"""
int main() {
  unsetenv("MADEIRA_D3D9_STRICT_MODES");
  const struct { UINT w, h, hz; } exact[] = {
    {1408, 648, 60}, {1408, 648, 0}, {1160, 800, 60}, {1160, 800, 0},
    {640, 480, 0}, {800, 600, 60}, {1024, 768, 0}, {1280, 720, 0},
  };
  for (const auto &c : exact) {
    if (!isPresentableFullscreenExtent(0, c.w, c.h, c.hz)) {
      printf("FAIL exact %ux%u@%u rejected\n", c.w, c.h, c.hz);
      return 1;
    }
  }
  if (g_env_reads != 0 || g_logs != 0) {
    printf("FAIL exact mode read env (%d) or logged (%d)\n", g_env_reads, g_logs);
    return 1;
  }

  // Blur (garbage refresh rate) + Monkey Island SE (3456x2234 Retina) + boundaries
  const struct { UINT w, h, hz; } rescued[] = {
    {1160, 800, 4199012}, {1160, 800, 1174409890},
    {3456, 2234, 0}, {1920, 1080, 60}, {2560, 1440, 144},
    {320, 200, 60}, {7680, 4320, 60},
  };
  for (const auto &c : rescued) {
    if (isPresentableFullscreenExtent_old(0, c.w, c.h, c.hz)) {
      printf("FAIL %ux%u@%u was already accepted by old\n", c.w, c.h, c.hz);
      return 1;
    }
    if (!isPresentableFullscreenExtent(0, c.w, c.h, c.hz)) {
      printf("FAIL rescued %ux%u@%u rejected\n", c.w, c.h, c.hz);
      return 1;
    }
  }
  if (g_logs != 4) {
    printf("FAIL expected 4 capped logs, got %d\n", g_logs);
    return 1;
  }

  // Out-of-range nonsense extents are still rejected
  const struct { UINT w, h, hz; } bad[] = {
    {0, 0, 0}, {319, 200, 60}, {320, 199, 60},
    {7681, 4320, 60}, {7680, 4321, 60}, {99999, 99999, 60},
  };
  for (const auto &c : bad) {
    if (isPresentableFullscreenExtent(0, c.w, c.h, c.hz)) {
      printf("FAIL bad extent %ux%u@%u accepted\n", c.w, c.h, c.hz);
      return 1;
    }
  }

  // Strict mode matches the old implementation everywhere
  setenv("MADEIRA_D3D9_STRICT_MODES", "1", 1);
  for (const auto &c : exact)
    if (isPresentableFullscreenExtent(0, c.w, c.h, c.hz) != isPresentableFullscreenExtent_old(0, c.w, c.h, c.hz))
      return 1;
  for (const auto &c : rescued)
    if (isPresentableFullscreenExtent(0, c.w, c.h, c.hz) != isPresentableFullscreenExtent_old(0, c.w, c.h, c.hz))
      return 1;
  for (const auto &c : bad)
    if (isPresentableFullscreenExtent(0, c.w, c.h, c.hz) != isPresentableFullscreenExtent_old(0, c.w, c.h, c.hz))
      return 1;

  printf("harness ok\n");
  return 0;
}
"""
    with tempfile.TemporaryDirectory() as t:
        src = pathlib.Path(t) / "d3d9_fs.cpp"
        src.write_text(harness)
        exe = pathlib.Path(t) / "d3d9_fs"
        b = subprocess.run([cxx, "-std=c++17", "-Wall", "-Werror", "-fsanitize=address,undefined", str(src), "-o", str(exe)],
                           capture_output=True, text=True)
        check("isPresentableFullscreenExtent compiles on the host", b.returncode == 0, b.stderr[-2000:])
        if b.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            check("enumerated modes, Blur's garbage Hz, Monkey Island's 3456x2234, bounds and strict mode behave as specified",
                  r.returncode == 0 and "harness ok" in r.stdout, r.stdout + r.stderr)

# --- the patch on the pinned source ---------------------------------------------------------------------------
candidates = [
    pathlib.Path(os.environ.get("DXMT_SRC_DIR", R / "dxmt")) / "src/d3d9/d3d9_interface.cpp",
    pathlib.Path.home() / "madeira-bcd/dxmt/src/d3d9/d3d9_interface.cpp",
]
target = next((c for c in candidates if c.is_file()), None)
if target is None:
    print("skip: dxmt/src/d3d9/d3d9_interface.cpp is not checked out")
else:
    with tempfile.TemporaryDirectory() as t:
        work = pathlib.Path(t)
        (work / "dxmt/src/d3d9").mkdir(parents=True)
        orig = target.read_text()
        # If the live ~/madeira-bcd copy was already patched, normalize back to OLD for the clean apply test
        if "madeira-bcd: [d3d9-modes] non-enumerated fullscreen" in orig:
            orig = orig.replace(new_fn, old_fn)
        (work / "dxmt/src/d3d9/d3d9_interface.cpp").write_text(orig)

        a = subprocess.run([sys.executable, str(PATCH)], cwd=work, capture_output=True, text=True)
        check("patch applies cleanly to d3d9_interface.cpp", a.returncode == 0, a.stdout + a.stderr)
        patched = (work / "dxmt/src/d3d9/d3d9_interface.cpp").read_text()
        b = subprocess.run([sys.executable, str(PATCH)], cwd=work, capture_output=True, text=True)
        check("patch is idempotent on a second run", b.returncode == 0 and (work / "dxmt/src/d3d9/d3d9_interface.cpp").read_text() == patched)
        check("only isPresentableFullscreenExtent changes", patched.replace(new_fn, old_fn) == orig)

wf = (R / ".github/workflows/build-ipa.yml").read_text()
check("CI runs check-dxmt-d3d9-fullscreen-extent.py and patch-dxmt-fullscreen-extent.py before the i386 farm key",
      "check-dxmt-d3d9-fullscreen-extent.py" in wf and "patch-dxmt-fullscreen-extent.py" in wf
      and wf.index("patch-dxmt-fullscreen-extent.py") < wf.index("id: i386rev"))

sys.exit(0 if ok else 1)
