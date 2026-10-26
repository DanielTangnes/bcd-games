// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host check for BCD's MIDI output driver (build/ntdll-unix/bcd_midi_ios.c): winmm's messages in
// mmdevapi's argument blocks, 64-bit and 32-bit (a guest window built from a heap block), against a
// synthesizer that only records what it is told. Run by tests/host/check-midi-driver.py.

#include "../../build/ntdll-unix/bcd_midi_ios.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ------------------------------------------------------------------ the recording synthesizer */

static char g_log[16384];
static int g_open_calls, g_close_calls, g_fail_open;
static const char *g_bank = "/fake/TimGM6mb.sf2";

static void rec(const char *fmt, ...)
{
    char t[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(t, sizeof t, fmt, ap);
    va_end(ap);
    strncat(g_log, t, sizeof g_log - strlen(g_log) - 2);
    strcat(g_log, ";");
}

const char *bcd_synth_bank_path(void) { return g_bank; }
int bcd_synth_open(char *why, size_t n)
{
    g_open_calls++;
    if (g_fail_open) { snprintf(why, n, "mock failure"); return -1; }
    rec("open");
    return 0;
}
void bcd_synth_close(void) { g_close_calls++; rec("close"); }
void bcd_synth_short(uint8_t s, uint8_t a, uint8_t b) { rec("%02x %02x %02x", s, a, b); }
void bcd_synth_sysex(const uint8_t *d, uint32_t n) { rec("sysex %u %02x..%02x", n, d[0], d[n - 1]); }
void bcd_synth_volume(float g) { rec("vol %.3f", g); }

/* ------------------------------------------------------------------ the 32-bit guest window */

#define GUEST_BASE 0x00400000u
#define ARENA_SIZE 0x10000u
static unsigned char *g_arena;               /* guest address a lives at g_arena + (a - GUEST_BASE) */
static unsigned long g_wow_base;             /* host = base + guest */
unsigned long ios_wow_base(void) { return g_wow_base; }
static uint32_t guest(const void *host) { return (uint32_t)((const unsigned char *)host - g_arena) + GUEST_BASE; }

/* ------------------------------------------------------------------ the checks */

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void expect_log(const char *want, const char *what)
{
    g_checks++;
    if (strcmp(g_log, want) != 0) { g_fail++; printf("FAIL %s (line %d):\n   want %s\n   got  %s\n", what, __LINE__, want, g_log); }
    g_log[0] = 0;
}

static void fresh(const char *midi_env)
{
    bcd_midi_test_reset();
    g_log[0] = 0;
    g_open_calls = g_close_calls = g_fail_open = 0;
    if (midi_env) setenv("MADEIRA_MIDI", midi_env, 1); else unsetenv("MADEIRA_MIDI");
    g_bank = "/fake/TimGM6mb.sf2";
}

static const char *silence_log(void)
{
    static char s[4096];
    unsigned ch;
    s[0] = 0;
    for (ch = 0; ch < 16; ch++) {
        char t[64];
        snprintf(t, sizeof t, "b%x 7b 00;b%x 78 00;b%x 79 00;", ch, ch, ch);
        strcat(s, t);
    }
    return s;
}

/* mmdevapi's argument blocks, 64-bit (UINT_PTR is 8 bytes) */
struct p64 { uint32_t dev_id, msg; uint64_t user, p1, p2; uint32_t *err; void *notify; };
struct n64 { int32_t send; uint16_t dev_id, msg; uint64_t p1, p2, callback; uint32_t flags; uint64_t device, instance; };
struct desc64 { uint64_t hmidi, callback, instance, dnDevNode; uint32_t streamID; uint16_t deviceID; };
struct hdr64 { uint64_t lpData; uint32_t length, recorded; uint64_t user; uint32_t flags; uint64_t lpNext, reserved; uint32_t offset; uint64_t res[8]; };
/* and 32-bit (the fields are 4 bytes; the pointers in them are guest addresses) */
struct p32 { uint32_t dev_id, msg, user, p1, p2, err, notify; };
struct n32 { int32_t send; uint16_t dev_id, msg; uint32_t p1, p2, callback, flags, device, instance; };
struct desc32 { uint32_t hmidi, callback, instance, dnDevNode; uint32_t streamID; uint16_t deviceID; };
struct hdr32 { uint32_t lpData, length, recorded, user, flags, lpNext, reserved, offset, res[8]; };

_Static_assert(sizeof(struct n64) == 56 && sizeof(struct n32) == 32, "notify layouts");
_Static_assert(__builtin_offsetof(struct hdr64, flags) == 24 && __builtin_offsetof(struct hdr64, offset) == 48, "hdr64");
_Static_assert(__builtin_offsetof(struct hdr32, flags) == 16 && __builtin_offsetof(struct hdr32, offset) == 28, "hdr32");

static unsigned msg64(unsigned msg, uint64_t user, uint64_t p1, uint64_t p2, struct n64 *n)
{
    uint32_t err = 0xdead;
    struct n64 local;
    struct p64 p = { 0, msg, user, p1, p2, &err, n ? n : &local };
    memset(n ? n : &local, 0xAA, sizeof local);
    bcd_midi_out_message64(&p);
    return err;
}

struct blk32 { struct p32 p; uint32_t err; struct n32 n; };
static struct n32 *g_n32;

static unsigned msg32(unsigned msg, uint32_t user, uint32_t p1, uint32_t p2)
{
    struct blk32 *b = (struct blk32 *)(g_arena + 0xF000);
    memset(b, 0xAA, sizeof *b);
    b->err = 0xdead;
    b->p = (struct p32){ 0, msg, user, p1, p2, guest(&b->err), guest(&b->n) };
    bcd_midi_out_message32(&b->p);
    g_n32 = &b->n;
    return b->err;
}

#define SHORT(a, b, c) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16))

/* ------------------------------------------------------------------ scenarios */

static void test_switch_and_bank(void)
{
    fresh("0");
    CHECK(bcd_midi_init() == 0, "env.MADEIRA_MIDI = 0 leaves the device out");
    CHECK(bcd_midi_out_num_devs() == 0, "no device when off");
    fresh(NULL);
    g_bank = NULL;
    CHECK(bcd_midi_init() == 0, "no sound bank, no device");
    fresh("1");
    CHECK(bcd_midi_init() == 1, "on with a bank");
    bcd_midi_release();
    fresh(NULL);
    CHECK(bcd_midi_init() == 1, "unset means on");
    CHECK(bcd_midi_out_num_devs() == 1, "one device");
    CHECK(g_open_calls == 0, "init builds nothing");
    bcd_midi_release();
    CHECK(bcd_midi_out_num_devs() == 0, "after the last release there is no device");
    fresh("yes");
    CHECK(bcd_midi_init() == 1, "only 0 turns it off");
    bcd_midi_release();
}

static void test_caps_counts64(void)
{
    uint16_t caps[42];
    uint32_t err = 0xdead;
    struct n64 n;
    fresh(NULL);
    bcd_midi_init();
    CHECK(msg64(1, 0, 0, 0, NULL) == 1, "MODM_GETNUMDEVS is 1");
    memset(caps, 0xEE, sizeof caps);
    CHECK(msg64(2, 0, (uintptr_t)caps, sizeof caps, NULL) == 0, "MODM_GETDEVCAPS");
    CHECK(caps[0] == 0x00FF && caps[1] == 1, "maker ids");
    CHECK(caps[4] == 'B' && caps[5] == 'C' && caps[6] == 'D' && caps[7] == ' ' && caps[8] == 'G' && caps[21] == 'r' && caps[22] == 0,
          "name \"BCD GM Synthesizer\"");
    CHECK(caps[36] == 2 && caps[37] == 32 && caps[38] == 32 && caps[39] == 0xFFFF, "MOD_SYNTH, 32 voices, 32 notes, 16 channels");
    CHECK(caps[40] == 1 && caps[41] == 0, "dwSupport = MIDICAPS_VOLUME");
    memset(caps, 0xEE, sizeof caps);
    CHECK(msg64(2, 0, (uintptr_t)caps, 16, NULL) == 0 && caps[0] == 0x00FF && caps[8] == 0xEEEE, "a short buffer gets only its size");
    CHECK(msg64(2, 0, 0, 84, NULL) == 11, "no buffer: invalid parameter");
    {
        struct p64 p = { 7, 2, 0, (uintptr_t)caps, sizeof caps, &err, &n };
        bcd_midi_out_message64(&p);
        CHECK(err == 2, "device 7 is a bad device id, got %u", err);
    }
    {   /* the input side and the auxiliary side have no devices: a count of 0, never the error code */
        struct p64 q = { 0, 53, 0, 0, 0, &err, &n };
        err = 0xdead; memset(&n, 0xAA, sizeof n);
        bcd_midi_in_message64(&q);
        CHECK(err == 0, "MIDM_GETNUMDEVS is 0, got %u", err);
        CHECK(n.send == 0, "no notification from the input side");
        q.msg = 55;
        bcd_midi_in_message64(&q);
        CHECK(err == 8, "MIDM_OPEN is not supported, got %u", err);
        q.msg = 100;
        bcd_midi_in_message64(&q);
        CHECK(err == 0, "DRVM_INIT is fine, got %u", err);
        struct { uint32_t dev, msg; uint64_t user, p1, p2; uint32_t *err; } a = { 0, 3, 0, 0, 0, &err };
        err = 0xdead;
        bcd_midi_aux_message64(&a);
        CHECK(err == 0, "AUXDM_GETNUMDEVS is 0, got %u", err);
        a.msg = 4;
        bcd_midi_aux_message64(&a);
        CHECK(err == 8, "AUXDM_GETDEVCAPS is not supported, got %u", err);
    }
    {   /* DRVM_INIT / EXIT on the output side */
        CHECK(msg64(100, 0, 0, 0, NULL) == 0 && msg64(101, 0, 0, 0, NULL) == 0, "DRVM_INIT and DRVM_EXIT");
        CHECK(msg64(999, 0, 0, 0, NULL) == 8, "an unknown message is not supported");
    }
    bcd_midi_release();
}

static void test_session64(void)
{
    struct n64 n;
    struct desc64 desc = { 0x1234, 0xCAFE0000, 0x77, 0, 0, 0 };
    uint64_t instance = 0xBADBADBAD;
    uint32_t vol = 0;
    uint8_t sysex[] = { 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7 };
    struct hdr64 hdr;
    unsigned r;
    struct bcd_midi_stats st;
    char want[8192];

    fresh(NULL);
    bcd_midi_init();
    CHECK(msg64(3, (uintptr_t)&instance, 0, 0, &n) == 11, "MODM_OPEN without a descriptor is invalid");
    r = msg64(3, (uintptr_t)&instance, (uintptr_t)&desc, 0x00030000 | 2, &n);
    CHECK(r == 0, "MODM_OPEN -> %u", r);
    CHECK(n.send == 1 && n.msg == 0x3C7 && n.dev_id == 0, "MOM_OPEN notification: send %d msg %x", n.send, n.msg);
    CHECK(n.callback == 0xCAFE0000 && n.instance == 0x77 && n.device == 0x1234 && n.flags == 3,
          "callback info: cb %llx inst %llx dev %llx flags %u", (unsigned long long)n.callback, (unsigned long long)n.instance,
          (unsigned long long)n.device, n.flags);
    CHECK(instance == 0x4D490001u, "winmm's dwDriverInstance now names the handle: %llx", (unsigned long long)instance);
    expect_log("open;vol 1.000;", "the first open builds the synthesizer once and sets the volume");

    CHECK(msg64(7, instance, SHORT(0x90, 0x3C, 0x64), 0, NULL) == 0, "note on");
    CHECK(msg64(7, instance, 0x623E, 0, NULL) == 0, "data bytes only: running status");
    CHECK(msg64(7, instance, SHORT(0xC1, 0x05, 0x55), 0, NULL) == 0, "program change");
    CHECK(msg64(7, instance, 0x0B, 0, NULL) == 0, "running status after a two-byte message");
    CHECK(msg64(7, instance, SHORT(0xB2, 7, 0x0B), 0, NULL) == 0, "controller");
    CHECK(msg64(7, instance, SHORT(0xE3, 0x00, 0x40), 0, NULL) == 0, "pitch wheel");
    CHECK(msg64(7, instance, SHORT(0xD4, 0x30, 0x77), 0, NULL) == 0, "channel pressure");
    CHECK(msg64(7, instance, SHORT(0x80, 0x3C, 0x40), 0, NULL) == 0, "note off");
    CHECK(msg64(7, instance, 0xF8, 0, NULL) == 0, "timing clock is ignored");
    CHECK(msg64(7, instance, 0xFE, 0, NULL) == 0, "active sensing is ignored");
    expect_log("90 3c 64;90 3e 62;c1 05 00;c1 0b 00;b2 07 0b;e3 00 40;d4 30 00;80 3c 40;",
               "short messages: a program change and channel pressure are two bytes; a data-only message takes the last status");
    CHECK(msg64(7, instance, SHORT(0xF0, 0, 0), 0, NULL) == 0, "F0 as a short message");
    CHECK(msg64(7, instance, 0x40, 0, NULL) == 0, "data after a system message has no status");
    expect_log("", "a system exclusive start ends running status; the data after it is dropped");
    CHECK(msg64(7, instance, 0xFF, 0, NULL) == 0, "system reset");
    snprintf(want, sizeof want, "%s", silence_log());
    expect_log(want, "system reset silences every channel");

    memset(&hdr, 0, sizeof hdr);
    hdr.lpData = (uintptr_t)sysex; hdr.length = sizeof sysex;
    CHECK(msg64(8, instance, (uintptr_t)&hdr, sizeof hdr, &n) == 64, "long data before prepare: MIDIERR_UNPREPARED");
    CHECK(msg64(5, instance, (uintptr_t)&hdr, sizeof hdr, NULL) == 0 && (hdr.flags & 2), "prepare sets MHDR_PREPARED");
    CHECK(msg64(8, instance, (uintptr_t)&hdr, sizeof hdr, &n) == 0, "long data");
    CHECK(n.send == 1 && n.msg == 0x3C9 && n.p1 == (uintptr_t)&hdr && n.callback == 0xCAFE0000, "MOM_DONE carries the header pointer");
    CHECK((hdr.flags & 1) && !(hdr.flags & 4) && (hdr.flags & 2), "header flags DONE|PREPARED, got %x", hdr.flags);
    expect_log("sysex 6 f0..f7;", "the system exclusive message reaches the synthesizer whole");
    hdr.flags |= 4;
    CHECK(msg64(8, instance, (uintptr_t)&hdr, sizeof hdr, &n) == 65, "a header still queued: MIDIERR_STILLPLAYING");
    CHECK(msg64(6, instance, (uintptr_t)&hdr, sizeof hdr, NULL) == 65, "unprepare of a queued header: still playing");
    hdr.flags &= ~4u;
    CHECK(msg64(6, instance, (uintptr_t)&hdr, sizeof hdr, NULL) == 0 && !(hdr.flags & 2), "unprepare");
    sysex[5] = 0x00;
    hdr.flags = 0;
    msg64(5, instance, (uintptr_t)&hdr, sizeof hdr, NULL);
    CHECK(msg64(8, instance, (uintptr_t)&hdr, sizeof hdr, &n) == 0 && n.msg == 0x3C9, "a broken message still completes its buffer");
    expect_log("", "a system exclusive message without F7 is not sent");
    CHECK(msg64(5, instance, (uintptr_t)&hdr, 8, NULL) == 11, "prepare with a header size below dwOffset is invalid");
    hdr.lpData = 0;
    hdr.flags = 0;
    CHECK(msg64(5, instance, (uintptr_t)&hdr, sizeof hdr, NULL) == 11, "prepare without data is invalid");
    CHECK(msg64(8, instance, 0, sizeof hdr, &n) == 11, "long data without a header is invalid");

    CHECK(msg64(11, instance, 0x40008000u, 0, NULL) == 0, "set volume");
    expect_log("vol 0.500;", "the louder side is the master gain");
    CHECK(msg64(10, instance, (uintptr_t)&vol, 0, NULL) == 0 && vol == 0x40008000u, "get volume %x", vol);
    CHECK(msg64(10, instance, 0, 0, NULL) == 11, "get volume without a place for it is invalid");
    CHECK(msg64(9, instance, 0, 0, NULL) == 0, "reset");
    snprintf(want, sizeof want, "%s", silence_log());
    expect_log(want, "reset silences every channel");
    CHECK(msg64(12, instance, 0, 0, NULL) == 8, "cache patches: not supported");

    r = msg64(4, instance, 0, 0, &n);
    CHECK(r == 0 && n.send == 1 && n.msg == 0x3C8 && n.callback == 0xCAFE0000 && n.instance == 0x77, "MOM_CLOSE (%u)", r);
    CHECK(g_close_calls == 1, "closed once");
    expect_log("close;", "the synthesizer went down with the last handle");
    CHECK(msg64(7, instance, SHORT(0x90, 0x3C, 0x64), 0, NULL) == 0, "data after close");
    expect_log("", "no sound after close");
    CHECK(msg64(4, instance, 0, 0, &n) == 0 && n.send == 0, "a second close is harmless");
    bcd_midi_stats(&st);
    CHECK(st.opens == 1 && st.closes == 1 && st.notes == 1 + 1 + 0 && st.program_changes == 2 && st.controllers == 1 && st.sysex == 1
          && st.bad_sysex == 1 && st.running_status == 2 + 0 && st.dropped >= 2,
          "stats: opens %u closes %u notes %u pc %u cc %u sysex %u bad %u running %u dropped %u", st.opens, st.closes, st.notes,
          st.program_changes, st.controllers, st.sysex, st.bad_sysex, st.running_status, st.dropped);
    bcd_midi_release();
}

static void test_two_handles(void)
{
    struct n64 n;
    struct desc64 a = { 1, 0xAAAA, 11, 0, 0, 0 }, b = { 2, 0xBBBB, 22, 0, 0, 0 };
    uint64_t ia = 0, ib = 0;
    fresh(NULL);
    bcd_midi_init();
    CHECK(msg64(3, (uintptr_t)&ia, (uintptr_t)&a, 0x30000, &n) == 0 && n.callback == 0xAAAA, "first open");
    CHECK(msg64(3, (uintptr_t)&ib, (uintptr_t)&b, 0x30000, &n) == 0 && n.callback == 0xBBBB, "second open");
    CHECK(ia != ib && ia == 0x4D490001u && ib == 0x4D490002u, "two instance values: %llx %llx", (unsigned long long)ia, (unsigned long long)ib);
    CHECK(g_open_calls == 1, "the synthesizer is built once for two handles");
    CHECK(msg64(4, ia, 0, 0, &n) == 0 && n.callback == 0xAAAA && g_close_calls == 0, "closing the first leaves the synthesizer up");
    g_log[0] = 0;
    CHECK(msg64(7, ib, SHORT(0x90, 0x3C, 0x64), 0, NULL) == 0, "the second handle still plays");
    expect_log("90 3c 64;", "still plays");
    CHECK(msg64(3, (uintptr_t)&ia, (uintptr_t)&a, 0x30000, &n) == 0 && ia == 0x4D490001u, "the freed slot is used again");
    CHECK(msg64(4, ib, 0, 0, &n) == 0 && n.callback == 0xBBBB && g_close_calls == 0, "closing the second leaves the reopened first");
    CHECK(msg64(4, ia, 0, 0, &n) == 0 && g_close_calls == 1, "the last close takes the synthesizer down");

    fresh(NULL);   /* a handle left open when the driver is released: a game that ended without closing */
    bcd_midi_init();
    msg64(3, (uintptr_t)&ia, (uintptr_t)&a, 0, &n);
    bcd_midi_release();
    CHECK(g_close_calls == 1, "the last release closes a synthesizer left open");
    bcd_midi_init();
    CHECK(msg64(3, (uintptr_t)&ia, (uintptr_t)&a, 0, &n) == 0 && ia == 0x4D490001u && g_open_calls == 2, "and a new session starts clean");
    bcd_midi_release();

    fresh(NULL);   /* an engine that does not start */
    bcd_midi_init();
    g_fail_open = 1;
    CHECK(msg64(3, (uintptr_t)&ia, (uintptr_t)&a, 0, &n) == 1 && n.send == 0, "an engine that does not start fails the open with no notification");
    g_fail_open = 0;
    CHECK(msg64(3, (uintptr_t)&ia, (uintptr_t)&a, 0, &n) == 0, "and the next open can succeed");
    bcd_midi_release();

    fresh(NULL);   /* nine handles: the table is full, the ninth open says so */
    bcd_midi_init();
    {
        int i;
        uint64_t inst[10];
        unsigned last = 0;
        for (i = 0; i < 9; i++) last = msg64(3, (uintptr_t)&inst[i], (uintptr_t)&a, 0, &n);
        CHECK(last == 6, "the ninth open gets MMSYSERR_NODRIVER, got %u", last);
    }
    bcd_midi_release();
}

static void test_session32(void)
{
    struct desc32 *desc = (struct desc32 *)(g_arena + 0x100);
    struct hdr32 *hdr = (struct hdr32 *)(g_arena + 0x200);
    uint32_t *instance = (uint32_t *)(g_arena + 0x300);
    uint32_t *vol = (uint32_t *)(g_arena + 0x310);
    uint8_t *sysex = g_arena + 0x400;
    uint16_t *caps = (uint16_t *)(g_arena + 0x500);
    unsigned r;
    static const uint8_t sx[] = { 0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7 };
    struct p32 *in = (struct p32 *)(g_arena + 0x600);
    struct n32 *innote = (struct n32 *)(g_arena + 0x640);
    uint32_t *err_cell = (uint32_t *)(g_arena + 0x680);
    struct { uint32_t dev, msg, user, p1, p2, err; } *aux = (void *)(g_arena + 0x6A0);
    struct bcd_midi_stats st;

    fresh(NULL);
    bcd_midi_init();
    memset(g_arena, 0, 0x1000);
    *desc = (struct desc32){ 0x5678, 0xC0DE0000, 0x99, 0, 0, 0 };
    memcpy(sysex, sx, sizeof sx);
    *instance = 0xBAD;
    CHECK(msg32(1, 0, 0, 0) == 1, "32-bit MODM_GETNUMDEVS");
    CHECK(msg32(2, 0, guest(caps), 84) == 0 && caps[0] == 0x00FF && caps[4] == 'B' && caps[36] == 2 && caps[39] == 0xFFFF,
          "32-bit caps are written into the window");
    CHECK(msg32(2, 0, 0, 84) == 11, "32-bit caps without a buffer: invalid parameter");
    CHECK(msg32(3, guest(instance), 0, 0) == 11, "32-bit open without a descriptor: invalid parameter");
    r = msg32(3, guest(instance), guest(desc), 0x00030000);
    CHECK(r == 0, "32-bit open -> %u", r);
    CHECK(g_n32->send == 1 && g_n32->msg == 0x3C7 && g_n32->dev_id == 0 && g_n32->callback == 0xC0DE0000 && g_n32->flags == 3
          && g_n32->device == 0x5678 && g_n32->instance == 0x99 && g_n32->p1 == 0 && g_n32->p2 == 0,
          "32-bit MOM_OPEN notification in the 32-bit layout: send %d msg %x cb %x flags %u dev %x inst %x", g_n32->send, g_n32->msg,
          g_n32->callback, g_n32->flags, g_n32->device, g_n32->instance);
    CHECK(*instance == 0x4D490001u, "winmm's 4-byte dwDriverInstance names the handle: %x", *instance);
    expect_log("open;vol 1.000;", "32-bit open builds the synthesizer");

    CHECK(msg32(7, *instance, SHORT(0x90, 0x3C, 0x64), 0) == 0, "32-bit note on");
    CHECK(msg32(7, *instance, SHORT(0xC0, 0x30, 0), 0) == 0, "32-bit program change");
    CHECK(msg32(7, *instance, 0x33, 0) == 0, "32-bit running status");
    expect_log("90 3c 64;c0 30 00;c0 33 00;", "32-bit short messages");

    hdr->lpData = guest(sysex);
    hdr->length = sizeof sx;
    CHECK(msg32(8, *instance, guest(hdr), 64) == 64, "32-bit long data before prepare");
    CHECK(msg32(5, *instance, guest(hdr), 64) == 0 && (hdr->flags & 2), "32-bit prepare sets the flag at offset 16");
    CHECK(msg32(5, *instance, guest(hdr), 64) == 0 && (hdr->flags & 2), "a prepared header is accepted again");
    r = msg32(8, *instance, guest(hdr), 64);
    CHECK(r == 0 && g_n32->send == 1 && g_n32->msg == 0x3C9 && g_n32->p1 == guest(hdr) && g_n32->callback == 0xC0DE0000,
          "32-bit MOM_DONE names the guest header (%u, p1 %x, header %x)", r, g_n32->p1, guest(hdr));
    CHECK((hdr->flags & 1) && (hdr->flags & 2) && !(hdr->flags & 4), "32-bit header flags %x", hdr->flags);
    expect_log("sysex 11 f0..f7;", "32-bit system exclusive reaches the synthesizer through the guest pointer");
    CHECK(msg32(6, *instance, guest(hdr), 64) == 0 && !(hdr->flags & 2), "32-bit unprepare");
    hdr->flags = 0; hdr->lpData = 0;
    CHECK(msg32(5, *instance, guest(hdr), 64) == 11, "32-bit prepare without data");
    CHECK(msg32(5, *instance, guest(hdr), 8) == 11, "32-bit prepare below dwOffset (28 bytes)");

    CHECK(msg32(11, *instance, 0x20004000u, 0) == 0, "32-bit set volume");
    expect_log("vol 0.250;", "32-bit volume");
    CHECK(msg32(10, *instance, guest(vol), 0) == 0 && *vol == 0x20004000u, "32-bit get volume %x", *vol);

    /* MIDI in and the auxiliary side, 32-bit blocks */
    *in = (struct p32){ 0, 53, 0, 0, 0, guest(err_cell), guest(innote) };
    *err_cell = 0xdead; innote->send = 1;
    bcd_midi_in_message32(in);
    CHECK(*err_cell == 0 && innote->send == 0, "32-bit MIDM_GETNUMDEVS is 0 and sends nothing (%u)", *err_cell);
    in->msg = 59;
    bcd_midi_in_message32(in);
    CHECK(*err_cell == 8, "32-bit MIDM_ADDBUFFER is not supported");
    aux->dev = 0; aux->msg = 3; aux->user = aux->p1 = aux->p2 = 0; aux->err = guest(err_cell);
    *err_cell = 0xdead;
    bcd_midi_aux_message32(aux);
    CHECK(*err_cell == 0, "32-bit AUXDM_GETNUMDEVS is 0, got %u", *err_cell);
    aux->msg = 5;
    bcd_midi_aux_message32(aux);
    CHECK(*err_cell == 8, "32-bit AUXDM_GETVOLUME is not supported");

    r = msg32(4, *instance, 0, 0);
    CHECK(r == 0 && g_n32->send == 1 && g_n32->msg == 0x3C8 && g_n32->callback == 0xC0DE0000 && g_n32->instance == 0x99, "32-bit MOM_CLOSE (%u)", r);
    expect_log("close;", "32-bit close takes the synthesizer down");
    CHECK(msg32(4, *instance, 0, 0) == 0 && g_n32->send == 0, "a second 32-bit close is harmless");
    bcd_midi_stats(&st);
    CHECK(st.opens == 1 && st.closes == 1 && st.notes == 1 && st.program_changes == 2 && st.sysex == 1 && st.running_status == 1,
          "32-bit stats: notes %u pc %u sysex %u running %u", st.notes, st.program_changes, st.sysex, st.running_status);
    bcd_midi_release();
}

struct waiter { unsigned timeout; int result; double secs; };
static void *waiter_main(void *arg)
{
    struct waiter *w = arg;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    w->result = bcd_midi_notify_wait(w->timeout);
    clock_gettime(CLOCK_MONOTONIC, &b);
    w->secs = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
    return NULL;
}

static void test_notify_thread(void)
{
    struct waiter w = { 50, -1, 0 }, w2 = { 5000, -1, 0 };
    pthread_t t, t2;
    struct timespec nap = { 0, 100 * 1000 * 1000 };
    fresh(NULL);
    bcd_midi_init();
    /* a wait with nothing to report returns by itself with "not quit", the PE loop calls it again */
    pthread_create(&t, NULL, waiter_main, &w);
    pthread_join(t, NULL);
    CHECK(w.result == 0 && w.secs >= 0.04 && w.secs < 1.0, "an idle wait times out (result %d, %.3f s)", w.result, w.secs);
    /* a release wakes a long wait at once, and it says quit */
    pthread_create(&t2, NULL, waiter_main, &w2);
    nanosleep(&nap, NULL);
    bcd_midi_release();
    pthread_join(t2, NULL);
    CHECK(w2.result == 1 && w2.secs < 1.0, "release ends the wait (result %d, %.3f s)", w2.result, w2.secs);
    /* a thread that was between two waits when the release came still ends, for a few seconds after it */
    w.result = -1;
    pthread_create(&t, NULL, waiter_main, &w);
    pthread_join(t, NULL);
    CHECK(w.result == 1, "a wait begun just after a release ends at once");
}

int main(void)
{
    g_arena = calloc(1, ARENA_SIZE);
    g_wow_base = (unsigned long)g_arena - GUEST_BASE;
    test_switch_and_bank();
    test_caps_counts64();
    test_session64();
    test_two_handles();
    test_session32();
    test_notify_thread();
    printf("%d checks, %d failed\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
