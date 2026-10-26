// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host check for BCD's MIDI synthesizer (build/ntdll-unix/bcd_midi_synth_ios.m) against Apple's real
// AUMIDISynth and the General MIDI SoundFont the app carries, rendered offline (no audio device needed):
// notes make sound, the percussion channel makes sound, the program changes the sound, volume scales it,
// a bad bank is refused, and closing gives the memory back. Run by tests/host/check-midi-synth.py.
// Compiled with -DBCD_SYNTH_OFFLINE, which swaps the speakers for bcd_synth_offline_render().

#include "../../build/ntdll-unix/bcd_midi_synth_ios.m"

#include <math.h>

extern int bcd_synth_offline_render(float *interleaved, uint32_t frames);
extern double bcd_synth_offline_footprint_mb(void);

static int g_checks, g_fail;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static double rms(const float *x, uint32_t frames)
{
    double s = 0;
    for (uint32_t i = 0; i < frames * 2; i++) s += (double)x[i] * x[i];
    return sqrt(s / (frames * 2));
}

/* how bright the sound is: the share of the energy in the upper half of the spectrum, estimated from first differences */
static double brightness(const float *x, uint32_t frames)
{
    double d = 0, e = 0;
    for (uint32_t i = 1; i < frames; i++) {
        double a = x[i * 2], b = x[(i - 1) * 2];
        d += (a - b) * (a - b);
        e += a * a;
    }
    return e > 0 ? d / e : 0;
}

static float g_buf[44100 * 2 * 2];

/* A chord of `count` notes on `channel`, held for a second and a half; the loudest 100 ms block's level. */
static double play(int channel, const uint8_t *keys, int count, double *bright)
{
    const uint32_t block = 4410, blocks = 15;
    double peak = 0;
    for (int i = 0; i < count; i++) bcd_synth_short(0x90 | channel, keys[i], 100);
    for (uint32_t b = 0; b < blocks; b++) {
        if (bcd_synth_offline_render(g_buf, block) != (int)block) return -1;
        double r = rms(g_buf, block);
        if (r > peak) peak = r;
        if (b == 3 && bright) *bright = brightness(g_buf, block);
    }
    for (int i = 0; i < count; i++) bcd_synth_short(0x80 | channel, keys[i], 0);
    for (int b = 0; b < 8; b++) bcd_synth_offline_render(g_buf, block);   /* let the release tail die out */
    return peak;
}

int main(int argc, char **argv)
{
    char why[200] = "";
    const uint8_t chord[] = { 60, 64, 67 }, bass[] = { 36 }, drums[] = { 36, 38, 42 };
    double bright_piano = 0, bright_strings = 0, quiet, loud;
    double base;

    if (argc < 2) { printf("usage: midi_synth_host <sound bank>\n"); return 2; }
    setenv("MADEIRA_MIDI_SOUNDFONT", argv[1], 1);
    const char *bank = bcd_synth_bank_path();
    CHECK(bank && strcmp(bank, argv[1]) == 0, "env.MADEIRA_MIDI_SOUNDFONT names the bank: %s", bank ? bank : "(none)");

    /* The first open in a process loads Apple's audio frameworks and component registry, which stay: about 14 MB that no close
     * gives back. One open and close first, so that the numbers below are what each further open costs. */
    CHECK(bcd_synth_open(why, sizeof why) == 0, "the first open (warm-up): %s", why);
    bcd_synth_close();
    base = footprint_mb();
    CHECK(bcd_synth_open(why, sizeof why) == 0, "the synthesizer opens: %s", why);
    CHECK(bcd_synth_open(why, sizeof why) == 0, "a second open while up is harmless");
    double up = footprint_mb() - base;
    printf("memory while open: %+.1f MB\n", up);
    CHECK(up < 120, "the synthesizer and the bank stay below 120 MB (%.1f)", up);

    /* a silent engine renders silence */
    CHECK(bcd_synth_offline_render(g_buf, 4410) == 4410 && rms(g_buf, 4410) < 1e-6, "silence before any note");

    double piano = play(0, chord, 3, &bright_piano);
    CHECK(piano > 0.01, "a piano chord is audible (rms %.4f)", piano);
    bcd_synth_short(0xC1, 48, 0);   /* strings on channel 2 */
    double strings = play(1, chord, 3, &bright_strings);
    CHECK(strings > 0.01, "strings are audible (rms %.4f)", strings);
    CHECK(fabs(bright_piano - bright_strings) > 1e-4 || fabs(piano - strings) > 1e-3, "the program change changes the sound (%.5f vs %.5f)", bright_piano, bright_strings);
    bcd_synth_short(0xC2, 33, 0);
    double bassd = play(2, bass, 1, NULL);
    CHECK(bassd > 0.005, "a bass note is audible (rms %.4f)", bassd);
    double kit = play(9, drums, 3, NULL);
    CHECK(kit > 0.01, "the percussion channel plays the drum kit (rms %.4f)", kit);

    /* volume */
    bcd_synth_volume(1.0f);
    for (int b = 0; b < 10; b++) bcd_synth_offline_render(g_buf, 4410);   /* a gain change ramps: let it settle */
    loud = play(0, chord, 3, NULL);
    bcd_synth_volume(0.25f);
    for (int b = 0; b < 10; b++) bcd_synth_offline_render(g_buf, 4410);
    quiet = play(0, chord, 3, NULL);
    CHECK(quiet > 0 && fabs(quiet / loud - 0.25) < 0.05, "volume 0.25 scales the level to a quarter (%.3f)", loud > 0 ? quiet / loud : -1);
    bcd_synth_volume(1.0f);

    /* a General MIDI reset and a GS reset are accepted; sound still plays afterwards */
    {
        const uint8_t gm[] = { 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7 };
        const uint8_t gs[] = { 0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7 };
        bcd_synth_sysex(gm, sizeof gm);
        bcd_synth_sysex(gs, sizeof gs);
        double after = play(0, chord, 3, NULL);
        CHECK(after > 0.01, "sound after a GM and a GS reset (rms %.4f)", after);
    }

    /* all sound off silences a held note */
    bcd_synth_short(0x90, 60, 100);
    bcd_synth_offline_render(g_buf, 4410);
    bcd_synth_short(0xB0, 120, 0);
    bcd_synth_offline_render(g_buf, 8820);
    bcd_synth_offline_render(g_buf, 4410);
    CHECK(rms(g_buf, 4410) < 0.001, "all sound off silences the held note (rms %.5f)", rms(g_buf, 4410));

    bcd_synth_close();
    double after_close = footprint_mb() - base;
    printf("memory after close: %+.1f MB\n", after_close);
    CHECK(after_close < up * 0.5 + 2, "closing gives most of the memory back (%.1f of %.1f MB left)", after_close, up);
    bcd_synth_close();   /* harmless twice */
    bcd_synth_short(0x90, 60, 100);   /* and events after close are ignored */

    /* open and close again, three times: no growth */
    double first_cycle = 0;
    for (int i = 0; i < 3; i++) {
        CHECK(bcd_synth_open(why, sizeof why) == 0, "reopen %d: %s", i, why);
        double p = play(0, chord, 3, NULL);
        CHECK(p > 0.01, "reopen %d sounds (rms %.4f)", i, p);
        bcd_synth_close();
        if (i == 0) first_cycle = footprint_mb();
    }
    CHECK(footprint_mb() - first_cycle < 15, "three cycles do not grow the process (%.1f MB)", footprint_mb() - first_cycle);

    /* a file that is not a sound bank is not used */
    {
        char path[] = "/tmp/bcd-midi-not-a-bank-XXXXXX";
        int fd = mkstemp(path);
        char junk[4096];
        memset(junk, 'x', sizeof junk);
        write(fd, junk, sizeof junk);
        close(fd);
        CHECK(!try_bank(path), "a file without a RIFF/sfbk header is refused");
        unlink(path);
    }
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
