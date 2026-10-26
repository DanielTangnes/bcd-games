// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The whole chain on the host, short of Wine: winmm's messages in mmdevapi's 64-bit argument block go through
// bcd_midi_ios.c into Apple's AUMIDISynth (bcd_midi_synth_ios.m, rendered offline) with the app's SoundFont.
// A short tune: the device opens, a General MIDI reset (long data), programs are chosen, a chord and a drum
// pattern play, the volume is set through MODM_SETVOLUME, the device closes. The sound must be there while it
// is open and gone after. Run by tests/host/check-midi-synth.py.

#include "../../build/ntdll-unix/bcd_midi_ios.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int bcd_synth_offline_render(float *interleaved, uint32_t frames);
unsigned long ios_wow_base(void) { return 0; }

static int g_checks, g_fail;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

struct p64 { uint32_t dev_id, msg; uint64_t user, p1, p2; uint32_t *err; void *notify; };
struct n64 { int32_t send; uint16_t dev_id, msg; uint64_t p1, p2, callback; uint32_t flags; uint64_t device, instance; };
struct desc64 { uint64_t hmidi, callback, instance, dnDevNode; uint32_t streamID; uint16_t deviceID; };
struct hdr64 { uint64_t lpData; uint32_t length, recorded; uint64_t user; uint32_t flags; uint64_t lpNext, reserved; uint32_t offset; uint64_t res[8]; };

static unsigned call(unsigned msg, uint64_t user, uint64_t p1, uint64_t p2)
{
    uint32_t err = 0xdead;
    struct n64 n;
    struct p64 p = { 0, msg, user, p1, p2, &err, &n };
    bcd_midi_out_message64(&p);
    return err;
}

static double rms(const float *x, uint32_t frames)
{
    double s = 0;
    for (uint32_t i = 0; i < frames * 2; i++) s += (double)x[i] * x[i];
    return sqrt(s / (frames * 2));
}

static float g_buf[4410 * 2];

static double burst(int blocks)
{
    double peak = 0;
    for (int i = 0; i < blocks; i++) {
        bcd_synth_offline_render(g_buf, 4410);
        double r = rms(g_buf, 4410);
        if (r > peak) peak = r;
    }
    return peak;
}

int main(int argc, char **argv)
{
    struct desc64 desc = { 1, 0, 0, 0, 0, 0 };
    uint64_t instance = 0;
    uint8_t gm[] = { 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7 };
    struct hdr64 hdr;
    if (argc < 2) return 2;
    setenv("MADEIRA_MIDI_SOUNDFONT", argv[1], 1);
    unsetenv("MADEIRA_MIDI");

    CHECK(bcd_midi_init() == 1, "init with the bank");
    CHECK(call(1, 0, 0, 0) == 1, "one output device");
    CHECK(call(3, (uintptr_t)&instance, (uintptr_t)&desc, 0) == 0, "open");
    memset(&hdr, 0, sizeof hdr);
    hdr.lpData = (uintptr_t)gm;
    hdr.length = sizeof gm;
    CHECK(call(5, instance, (uintptr_t)&hdr, sizeof hdr) == 0, "prepare");
    CHECK(call(8, instance, (uintptr_t)&hdr, sizeof hdr) == 0, "General MIDI reset");
    CHECK(call(6, instance, (uintptr_t)&hdr, sizeof hdr) == 0, "unprepare");
    CHECK(burst(2) < 1e-6, "silence so far");

    call(7, instance, 0x00C0 | (0 << 8), 0);                 /* piano on channel 1 */
    call(7, instance, 0x64u << 16 | 60 << 8 | 0x90, 0);       /* a chord, running status after the first */
    call(7, instance, 0x64u << 8 | 64, 0);
    call(7, instance, 0x64u << 8 | 67, 0);
    double chord = burst(10);
    CHECK(chord > 0.01, "the chord is heard (rms %.4f)", chord);

    call(7, instance, 0x64u << 16 | 36 << 8 | 0x99, 0);       /* a kick on the percussion channel */
    call(7, instance, 0x64u << 8 | 42, 0);                    /* and a hat, by running status */
    double drums = burst(5);
    CHECK(drums > 0.01, "drums are heard (rms %.4f)", drums);

    call(11, instance, 0x40004000u, 0);                       /* a quarter of the volume */
    burst(10);                                                /* the gain ramps */
    call(7, instance, 0x64u << 16 | 72 << 8 | 0x90, 0);
    double quieter = burst(10);
    CHECK(quieter < chord, "MODM_SETVOLUME makes it quieter (%.4f against %.4f)", quieter, chord);

    call(9, instance, 0, 0);                                  /* MODM_RESET silences everything */
    burst(10);
    CHECK(burst(3) < 0.001, "reset silences the held notes (%.5f)", burst(1));

    CHECK(call(4, instance, 0, 0) == 0, "close");
    call(7, instance, 0x64u << 16 | 60 << 8 | 0x90, 0);
    CHECK(bcd_synth_offline_render(g_buf, 4410) == -1, "after the last close the engine is gone");
    bcd_midi_release();
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
