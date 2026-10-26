#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Record when each Present happened, for the in-game HUD and the session summary.

winemetal's madeira_log_present_cadence() is where every Present of the process is counted
(madeira_get_present_count, which the old overlay read twice a second): the one place Direct3D 9, 10,
11 and 12 meet, because madeira-d3d12 presents through the same winemetal call. The count says how
many frames there were, not when, so a frame-time graph, the 1% and 0.1% lows and a session's
average could not be made from it. This patch makes that function also call bcd_frame_ring_push()
(app/Madeira/BCDFrameRing.c, linked into the app): one clock read and two relaxed atomics, no lock,
no allocation, no log line. It is a weak import, so a link without the app's ring still links and
the call is skipped.

Always on (a session without a HUD still gets its [session] summary line); it changes no frame's
timing beyond that handful of nanoseconds. Native only (winemetal unix side), not in the i386 farm
key. Idempotent; fails by name if the anchor moves. Run from the repository root.
"""
import pathlib
import sys

PATH = pathlib.Path("dxmt/src/winemetal/unix/winemetal_unix.c")
MARKER = "madeira-bcd frame ring"

OLD = """  uint64_t n = atomic_fetch_add_explicit(&g_madeira_present_count, 1, memory_order_relaxed) + 1;
"""
NEW = """  uint64_t n = atomic_fetch_add_explicit(&g_madeira_present_count, 1, memory_order_relaxed) + 1;
  {   /* madeira-bcd frame ring (tools/patch-winemetal-frame-ring.py): when this Present happened, for the HUD and the session summary */
    extern void bcd_frame_ring_push(void) __attribute__((weak_import));
    if (bcd_frame_ring_push)
      bcd_frame_ring_push();
  }
"""


def main():
    s = PATH.read_text()
    if MARKER in s:
        print("winemetal_unix.c: frame ring already patched")
        return 0
    if s.count(OLD) != 1:
        sys.exit(f"patch-winemetal-frame-ring: anchor found {s.count(OLD)} times (want 1) in {PATH}:\n{OLD}")
    PATH.write_text(s.replace(OLD, NEW))
    print("winemetal_unix.c: frame ring patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
