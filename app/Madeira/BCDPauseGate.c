// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDPauseGate.c
//  Madeira
//
//  See BCDPauseGate.h.

#include "BCDPauseGate.h"
#include "BCDFrameRing.h"

#include <pthread.h>
#include <stdatomic.h>

static _Atomic int g_pause;
static _Atomic int g_pause_waiting;
static pthread_mutex_t g_pause_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pause_cond = PTHREAD_COND_INITIALIZER;

static void pause_wait(void) {
    pthread_mutex_lock(&g_pause_lock);
    atomic_fetch_add_explicit(&g_pause_waiting, 1, memory_order_relaxed);
    while (atomic_load_explicit(&g_pause, memory_order_relaxed)) pthread_cond_wait(&g_pause_cond, &g_pause_lock);
    atomic_fetch_sub_explicit(&g_pause_waiting, 1, memory_order_relaxed);
    pthread_mutex_unlock(&g_pause_lock);
}

void bcd_pause_gate_pass(void) {
    if (atomic_load_explicit(&g_pause, memory_order_relaxed)) pause_wait();
}

void bcd_pause_set(int paused) {
    pthread_mutex_lock(&g_pause_lock);
    atomic_store_explicit(&g_pause, paused ? 1 : 0, memory_order_relaxed);
    if (!paused) {
        // The gap the pause made is not a stall of the game: the next frame starts a gap of its own.
        bcd_frame_forget_last();
        pthread_cond_broadcast(&g_pause_cond);
    }
    pthread_mutex_unlock(&g_pause_lock);
}

int bcd_pause_requested(void) { return atomic_load_explicit(&g_pause, memory_order_relaxed); }
int bcd_pause_waiting(void) { return atomic_load_explicit(&g_pause_waiting, memory_order_relaxed); }
