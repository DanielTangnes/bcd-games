#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Accept plausible non-enumerated fullscreen extents and uninitialized refresh rates in DXMT D3D9.

A fullscreen present on iOS does not switch display modes: MTLD3D9SwapChain composites its
backbuffer into a CAMetalLayer and scales it to the drawable. Two classes of real D3D9 games
failed CreateDevice with D3DERR_INVALIDCALL (0x8876086c) inside CanonicalisePresentParams ->
isPresentableFullscreenExtent:
  1. Blur (logs 8XZKXY, S465J5): passes a valid enumerated extent (1160x800, X8R8G8B8,
     windowed=0) with uninitialized stack garbage in FullScreen_RefreshRateInHz (4199012 in
     8XZKXY, 1174409890 in S465J5).
  2. The Secret of Monkey Island: Special Edition (Steam 32360, logs 0QM8ZF, FTZTQ1): reads a
     saved 3456x2234@0 fullscreen extent from Settings.ini (copied from a 16-inch MacBook Pro
     Retina display), which is neither in the phone's adapterModes (1408x648@60, 1160x800@60)
     nor in the fixed VGA/HD kPresentableExtents list.

When neither adapterModes nor kPresentableExtents matches, isPresentableFullscreenExtent now
accepts any plausible fullscreen extent in [320x200, 7680x4320] (and logs at most 4
"[d3d9-modes]" lines) unless env.MADEIRA_D3D9_STRICT_MODES=1 is set. Every extent that
matched adapterModes or kPresentableExtents before takes the exact path it took before;
nonsense extents (0x0, <320x200, >7680x4320) are still rejected.

Idempotent; fails by name if the anchor moves. Run from the repository root.
"""
import pathlib
import sys

PATH = pathlib.Path("dxmt/src/d3d9/d3d9_interface.cpp")
MARKER = "madeira-bcd: [d3d9-modes] non-enumerated fullscreen"

OLD = """static bool
isPresentableFullscreenExtent(UINT adapter, UINT width, UINT height, UINT refreshRate) {
  for (const auto &m : adapterModes(adapter)) {
    if (m.width != width || m.height != height)
      continue;
    if (refreshRate != 0 && refreshRateHzOr60(m) != refreshRate)
      continue;
    return true;
  }
  return std::any_of(std::begin(kPresentableExtents), std::end(kPresentableExtents), [&](const auto &e) {
    return e.width == width && e.height == height;
  });
}
"""

NEW = """static bool
isPresentableFullscreenExtent(UINT adapter, UINT width, UINT height, UINT refreshRate) {
  for (const auto &m : adapterModes(adapter)) {
    if (m.width != width || m.height != height)
      continue;
    if (refreshRate != 0 && refreshRateHzOr60(m) != refreshRate)
      continue;
    return true;
  }
  if (std::any_of(std::begin(kPresentableExtents), std::end(kPresentableExtents), [&](const auto &e) {
        return e.width == width && e.height == height;
      }))
    return true;
  /* madeira-bcd: [d3d9-modes] non-enumerated fullscreen: a fullscreen present here composites
   * its backbuffer into a CAMetalLayer and scales it to the drawable without switching display
   * modes. Blur (8XZKXY, S465J5) leaves FullScreen_RefreshRateInHz uninitialized on the stack
   * (1160x800@4199012 / 1174409890), and The Secret of Monkey Island: SE (0QM8ZF, FTZTQ1)
   * reads a 3456x2234 Retina resolution from its saved Settings.ini; rejecting either fails
   * CreateDevice with D3DERR_INVALIDCALL (0x8876086c). Accept any plausible fullscreen extent
   * in [320x200, 7680x4320] unless env.MADEIRA_D3D9_STRICT_MODES=1. */
  if (width >= 320 && height >= 200 && width <= 7680 && height <= 4320 &&
      env::getEnvVar("MADEIRA_D3D9_STRICT_MODES") != "1") {
    static int said = 0;
    if (said++ < 4)
      Logger::warn(str::format(
          "[d3d9-modes] accepting non-enumerated fullscreen ", width, "x", height, "@", refreshRate,
          " (scaled by the layer; env.MADEIRA_D3D9_STRICT_MODES=1 rejects it)"));
    return true;
  }
  return false;
}
"""


def main():
    s = PATH.read_text()
    if MARKER in s:
        print("d3d9_interface.cpp: non-enumerated fullscreen extent acceptance already present")
        return 0
    if s.count(OLD) != 1:
        print(f"::error::{PATH}: isPresentableFullscreenExtent anchor not found once -- dxmt moved, review this patch")
        return 1
    PATH.write_text(s.replace(OLD, NEW))
    print("d3d9_interface.cpp: isPresentableFullscreenExtent accepts [320x200, 7680x4320] fullscreen extents and garbage refresh rates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
