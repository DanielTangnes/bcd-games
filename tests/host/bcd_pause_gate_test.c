// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The behaviour of the Pause gate in app/Madeira/BCDPauseGate.c (called by BCDFrameRing.c) (tests/host/check-bcd-menu-items.py compiles this with it, under the address,
// undefined-behaviour and thread sanitizers, one at a time): open, the present path is not held up; shut, the thread that presents waits at
// the end of bcd_frame_ring_push() until the gate opens; the pause is not a stall in the session's statistics.
#include "BCDFrameRing.h"
#include "BCDPauseGate.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static int failures;
#define REQUIRE(cond, what) do { if (cond) printf("PASS: %s\n", what); else { printf("FAIL: %s\n", what); failures++; } } while (0)

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }

static _Atomic int g_returned;

static void *presenter(void *arg) {
    (void)arg;
    bcd_frame_ring_push();
    atomic_store(&g_returned, 1);
    return NULL;
}

int main(void) {
    bcd_frame_set_timebase(1, 1);   // a tick is a nanosecond

    REQUIRE(!bcd_pause_requested() && bcd_pause_waiting() == 0, "the gate starts open and nothing waits");
    double t0 = now_s();
    for (int i = 0; i < 20000; i++) bcd_frame_ring_push();
    REQUIRE(now_s() - t0 < 1.0, "open: twenty thousand presents are not held up");
    REQUIRE(bcd_frame_ring_count() == 20000, "every present is in the ring");

    bcd_frame_stats_begin();
    bcd_frame_ring_push();
    sleep_ms(5);
    bcd_frame_ring_push();
    sleep_ms(5);
    bcd_frame_ring_push();
    bcd_frame_summary before;
    bcd_frame_stats_read(&before);
    REQUIRE(before.frames == 2 && before.stalls == 0, "two gaps counted before the pause");

    bcd_pause_set(1);
    REQUIRE(bcd_pause_requested() == 1, "shut");
    atomic_store(&g_returned, 0);
    pthread_t thread;
    pthread_create(&thread, NULL, presenter, NULL);
    for (int i = 0; i < 200 && bcd_pause_waiting() == 0; i++) sleep_ms(5);
    REQUIRE(bcd_pause_waiting() == 1, "shut: the presenting thread waits at the gate");
    sleep_ms(200);
    REQUIRE(atomic_load(&g_returned) == 0, "... and stays there");
    REQUIRE(bcd_frame_ring_count() == 20004, "... its present was counted before it waited (the frame on its way to the screen)");
    bcd_frame_summary during;
    bcd_frame_stats_read(&during);
    REQUIRE(during.frames == 3 && during.stalls == 0, "... as a frame of its own, before the wait");

    bcd_pause_set(0);
    pthread_join(thread, NULL);
    REQUIRE(atomic_load(&g_returned) == 1 && bcd_pause_waiting() == 0, "open again: the thread goes on and nothing waits");

    bcd_frame_summary after;
    bcd_frame_stats_read(&after);
    uint64_t frames_with_waiter = after.frames;
    bcd_frame_ring_push();   // the first present after the pause
    bcd_frame_stats_read(&after);
    REQUIRE(after.frames == frames_with_waiter && after.stalls == 0, "the pause is not a frame, a stall or the worst frame of the session: the next present starts a gap of its own");

    // Several threads at once all wait, and all go on.
    bcd_pause_set(1);
    pthread_t many[6];
    atomic_store(&g_returned, 0);
    for (int i = 0; i < 6; i++) pthread_create(&many[i], NULL, presenter, NULL);
    for (int i = 0; i < 400 && bcd_pause_waiting() < 6; i++) sleep_ms(5);
    REQUIRE(bcd_pause_waiting() == 6, "six presenting threads all wait");
    bcd_pause_set(0);
    for (int i = 0; i < 6; i++) pthread_join(many[i], NULL);
    REQUIRE(bcd_pause_waiting() == 0 && atomic_load(&g_returned) == 1, "... and all go on");

    // Opening a gate that was never shut, and shutting and opening it again at once, do nothing harmful.
    bcd_pause_set(0);
    bcd_pause_set(1);
    bcd_pause_set(0);
    bcd_frame_ring_push();
    REQUIRE(bcd_pause_waiting() == 0 && !bcd_pause_requested(), "open, shut and open again with no thread: nothing waits");

    printf(failures == 0 ? "ALL PASS\n" : "%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
