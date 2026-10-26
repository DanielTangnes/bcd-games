// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDPauseGate.h
//  Madeira
//
//  The in-game menu's Pause (round 604): while the gate is shut, the thread that presents a frame waits at the end of bcd_frame_ring_push()
//  (BCDFrameRing.c calls bcd_pause_gate_pass() once a frame), so the game stands still at its next frame and the last picture stays on screen.
//  Open, which is how the process starts, it costs the present path one call and one relaxed load. The gate is its own file because the ring
//  must stay wait-free (tests/host/check-bcd-hud.py): the lock is taken here, and only while the game is paused.
//
//  Shut and open from the main thread (BCDPauseLive.swift).
//

#ifndef BCD_PAUSE_GATE_H
#define BCD_PAUSE_GATE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Called by the present path once a frame: returns at once while the gate is open, waits while it is shut.
void bcd_pause_gate_pass(void);

/// Shuts (1) or opens (0) the gate. Opening also tells the frame statistics to forget the newest present, so the wait is not counted as a frame.
void bcd_pause_set(int paused);

/// 1 while the gate is shut.
int bcd_pause_requested(void);

/// How many threads are waiting at the gate now. 0 with the gate shut means no frame has been presented since: the game is still drawing
/// one, or presents nothing (a loading screen, a program that is not drawn by Direct3D).
int bcd_pause_waiting(void);

#ifdef __cplusplus
}
#endif

#endif
