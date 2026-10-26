// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's MIDI output, the winmm driver side (see bcd_midi_ios.h). winmm's MIDI-out calls reach
// mmdevapi.dll's modMessage, which calls the midi_out_message slot of audio_null_ios.c with the argument
// block of dlls/mmdevapi/unixlib.h; the slot calls the functions here. One output device exists:
// "BCD GM Synthesizer", id 0, a software synthesizer (the same kind of device as Wine's CoreAudio MIDI
// Synth on macOS, wTechnology MOD_SYNTH), master volume only.
//
// Two argument-block widths. A 64-bit (ARM64EC) caller passes host pointers and 8-byte UINT_PTRs. A
// 32-bit (WoW64) caller passes 4-byte fields: every pointer inside the block, and the structures it points
// to (MIDIOPENDESC, MIDIHDR), are in the caller's guest window and need the window's base added
// (ios_wow_host_ptr in audio_null_ios.c, respelled below: this file carries no Wine headers, like that
// one). The notification the driver hands back (struct notify_context) has the same two widths.
//
// What this file never does: touch Apple frameworks (bcd_midi_synth_ios.m does), keep a Wine lock while it
// waits, or answer a message it does not understand with success (an unknown message is
// MMSYSERR_NOTSUPPORTED, and winmm's counts come back as numbers: GETNUMDEVS of the input side and of the
// auxiliary side are 0, never the error code).

#include "bcd_midi_ios.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ------------------------------------------------------------------ constants (mmsystem.h, mmddk.h) */

#define DRVM_INIT        100
#define DRVM_EXIT        101
#define DRVM_DISABLE     102
#define DRVM_ENABLE      103

#define MODM_GETNUMDEVS  1
#define MODM_GETDEVCAPS  2
#define MODM_OPEN        3
#define MODM_CLOSE       4
#define MODM_PREPARE     5
#define MODM_UNPREPARE   6
#define MODM_DATA        7
#define MODM_LONGDATA    8
#define MODM_RESET       9
#define MODM_GETVOLUME   10
#define MODM_SETVOLUME   11

#define MIDM_GETNUMDEVS  53
#define AUXDM_GETNUMDEVS 3

#define MMSYSERR_NOERROR      0u
#define MMSYSERR_ERROR        1u
#define MMSYSERR_BADDEVICEID  2u
#define MMSYSERR_NODRIVER     6u
#define MMSYSERR_NOTSUPPORTED 8u
#define MMSYSERR_INVALPARAM   11u
#define MIDIERR_UNPREPARED    64u
#define MIDIERR_STILLPLAYING  65u

#define MM_MOM_OPEN   0x3C7u
#define MM_MOM_CLOSE  0x3C8u
#define MM_MOM_DONE   0x3C9u

#define MHDR_DONE      0x00000001u
#define MHDR_PREPARED  0x00000002u
#define MHDR_INQUEUE   0x00000004u

#define CALLBACK_TYPEMASK 0x00070000u

#define MOD_SYNTH 2u
#define MIDICAPS_VOLUME 0x0001u

/* sizeof(MIDIHDR) up to dwOffset: the least a prepare/unprepare call must pass (winmm's own check). */
#define HDR64_DWOFFSET 48u
#define HDR32_DWOFFSET 28u

/* ------------------------------------------------------------------ the structures, by hand */

/* MIDIOUTCAPSW: the same 84 bytes in both widths (WORD, WORD, UINT, WCHAR[32], WORD x4, DWORD). */
struct midi_out_caps_w {
    uint16_t wMid, wPid;
    uint32_t vDriverVersion;
    uint16_t szPname[32];
    uint16_t wTechnology, wVoices, wNotes, wChannelMask;
    uint32_t dwSupport;
};
_Static_assert(sizeof(struct midi_out_caps_w) == 84, "MIDIOUTCAPSW is 84 bytes");

/* mmdevapi's struct midi_out_message_params / midi_in_message_params / aux_message_params. */
struct params64 {
    uint32_t dev_id, msg;
    uint64_t user, param_1, param_2;
    uint32_t *err;
    void *notify;
};
struct params32 {
    uint32_t dev_id, msg, user, param_1, param_2, err, notify;
};
struct aux64 {
    uint32_t dev_id, msg;
    uint64_t user, param_1, param_2;
    uint32_t *err;
};
struct aux32 {
    uint32_t dev_id, msg, user, param_1, param_2, err;
};

/* mmdevapi's struct notify_context (BOOL, WORD, WORD, UINT_PTR x3, UINT, HANDLE, UINT_PTR) in both widths. */
struct notify_ctx64 {
    int32_t send_notify;
    uint16_t dev_id, msg;
    uint64_t param_1, param_2, callback;
    uint32_t flags;
    uint64_t device, instance;
};
struct notify_ctx32 {
    int32_t send_notify;
    uint16_t dev_id, msg;
    uint32_t param_1, param_2, callback, flags, device, instance;
};
_Static_assert(sizeof(struct notify_ctx64) == 56, "notify_context, 64-bit");
_Static_assert(sizeof(struct notify_ctx32) == 32, "notify_context, 32-bit");

/* ------------------------------------------------------------------ the guest window (audio_null_ios.c respells the same) */

extern unsigned long ios_wow_base(void);   /* 0 when not a WoW process */

static inline void *wow_host(uint32_t addr)
{
    return addr ? (void *)(ios_wow_base() + (uintptr_t)addr) : NULL;
}

/* ------------------------------------------------------------------ state */

#define MAX_HANDLES 8
#define HANDLE_TAG  0x4D490000u   /* "MI": the value stored as winmm's dwDriverInstance, so a later message names its handle */

struct handle {
    int used;
    uint64_t hmidi, callback, instance;
    unsigned flags;                /* HIWORD of the callback type, as DriverCallback wants it */
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_wake = PTHREAD_COND_INITIALIZER;
static int g_loaded;               /* DRV_LOAD minus DRV_FREE */
static int g_open;                 /* handles open; the synthesizer lives while this is above 0 */
static int g_synth_up;
static struct handle g_handles[MAX_HANDLES];
static uint8_t g_running;          /* running status */
static uint32_t g_volume = 0xFFFFFFFFu;
static struct bcd_midi_stats g_stats;       /* since the process started */
static struct bcd_midi_stats g_session;     /* since the synthesizer was last built */
static int g_first_note_said;
static struct timespec g_up_since;
static struct timespec g_quit_until;        /* a release has happened: every notify wait ends until then */
static int g_said_off, g_said_nobank, g_said_ready;

/* ------------------------------------------------------------------ small helpers */

static void say(const char *fmt, ...)
{
    char line[256];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(line, sizeof line - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    line[n] = 0;
    fputs(line, stderr);
}

static double secs_since(const struct timespec *t)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)(now.tv_sec - t->tv_sec) + (double)(now.tv_nsec - t->tv_nsec) / 1e9;
}

static void add_ms(struct timespec *t, unsigned ms)
{
    t->tv_sec += ms / 1000;
    t->tv_nsec += (long)(ms % 1000) * 1000000L;
    if (t->tv_nsec >= 1000000000L) { t->tv_sec++; t->tv_nsec -= 1000000000L; }
}

static int later(const struct timespec *a, const struct timespec *b)
{
    return a->tv_sec > b->tv_sec || (a->tv_sec == b->tv_sec && a->tv_nsec > b->tv_nsec);
}

static int midi_on(void)
{
    const char *e = getenv("MADEIRA_MIDI");   /* 0: no MIDI device, as before this driver; unset or anything else: on */
    return !(e && strcmp(e, "0") == 0);
}

static struct handle *handle_for(uint64_t user)
{
    unsigned i;
    if ((user & 0xFFFF0000u) == HANDLE_TAG && (user & 0xFFFFu) >= 1 && (user & 0xFFFFu) <= MAX_HANDLES
        && g_handles[(user & 0xFFFFu) - 1].used)
        return &g_handles[(user & 0xFFFFu) - 1];
    for (i = MAX_HANDLES; i-- > 0;)             /* a message without our tag (winmm's own copy of the value is stale): the newest handle */
        if (g_handles[i].used) return &g_handles[i];
    return NULL;
}

static void fill_notify(struct bcd_midi_notify *n, const struct handle *h, unsigned msg, uint64_t p1, uint64_t p2)
{
    memset(n, 0, sizeof *n);
    n->send = 1;
    n->dev_id = 0;
    n->msg = msg;
    n->param_1 = p1;
    n->param_2 = p2;
    if (h) {
        n->callback = h->callback;
        n->flags = h->flags;
        n->device = h->hmidi;
        n->instance = h->instance;
    }
}

/* ------------------------------------------------------------------ the driver's life */

int bcd_midi_init(void)
{
    const char *bank;
    if (!midi_on()) {
        if (!g_said_off++) say("[midi] off (env.MADEIRA_MIDI = 0): no MIDI device");
        return 0;
    }
    bank = bcd_synth_bank_path();
    if (!bank) {
        if (!g_said_nobank++) say("[midi] no General MIDI sound bank found (the one the app carries, or any in Documents/SoundFonts): no MIDI device");
        return 0;
    }
    pthread_mutex_lock(&g_lock);
    g_loaded++;
    pthread_mutex_unlock(&g_lock);
    if (!g_said_ready++) {
        const char *slash = strrchr(bank, '/');
        say("[midi] \"BCD GM Synthesizer\" available (sound bank %s)", slash ? slash + 1 : bank);   /* the name, not the app's folder */
    }
    return 1;
}

static void close_synth_locked(void)
{
    if (!g_synth_up) return;
    g_synth_up = 0;
    bcd_synth_close();
    say("[midi] closed: %u notes, %u program changes, %u controllers, %u other channel messages, %u system exclusive "
        "(%u refused), %u dropped, in %.1f s", g_session.notes, g_session.program_changes, g_session.controllers,
        g_session.other_channel, g_session.sysex, g_session.bad_sysex, g_session.dropped, secs_since(&g_up_since));
}

void bcd_midi_release(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_loaded > 0) g_loaded--;
    /* Every notify thread ends, not only this process's: the driver has no notification to deliver, a thread
     * that ends early costs nothing, and a thread that misses its quit would hold DRV_FREE for good. */
    clock_gettime(CLOCK_MONOTONIC, &g_quit_until);
    add_ms(&g_quit_until, 3000);
    pthread_cond_broadcast(&g_wake);
    if (g_loaded == 0) {
        unsigned i;
        for (i = 0; i < MAX_HANDLES; i++) g_handles[i].used = 0;
        g_open = 0;
        g_running = 0;
        close_synth_locked();
    }
    pthread_mutex_unlock(&g_lock);
}

int bcd_midi_notify_wait(unsigned timeout_ms)
{
    struct timespec now, until;
    int quit;
    pthread_mutex_lock(&g_lock);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (g_loaded <= 0) { quit = 1; break; }   /* nothing loaded (or released): there is nothing to wait for */
        if (g_quit_until.tv_sec && later(&g_quit_until, &now)) { quit = 1; break; }
        /* pthread_cond_timedwait takes the wall clock; a short relative wait is all that is wanted. */
        clock_gettime(CLOCK_REALTIME, &until);
        add_ms(&until, timeout_ms);
        if (pthread_cond_timedwait(&g_wake, &g_lock, &until) == ETIMEDOUT) { quit = 0; break; }
    }
    pthread_mutex_unlock(&g_lock);
    return quit;
}

/* ------------------------------------------------------------------ output device operations */

unsigned bcd_midi_out_num_devs(void)
{
    unsigned n;
    pthread_mutex_lock(&g_lock);
    n = g_loaded > 0 ? 1u : 0u;
    pthread_mutex_unlock(&g_lock);
    return n;
}

unsigned bcd_midi_out_dev_caps(unsigned dev, void *caps, unsigned size)
{
    static const char name[] = "BCD GM Synthesizer";
    struct midi_out_caps_w c;
    unsigned i;
    if (!caps) return MMSYSERR_INVALPARAM;
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    memset(&c, 0, sizeof c);
    c.wMid = 0x00FF;                 /* Wine's CoreAudio driver says the same: no registered maker */
    c.wPid = 0x0001;
    c.vDriverVersion = 0x0001;
    for (i = 0; i + 1 < sizeof name; i++) c.szPname[i] = (uint8_t)name[i];
    c.wTechnology = (uint16_t)MOD_SYNTH;
    c.wVoices = 32;
    c.wNotes = 32;
    c.wChannelMask = 0xFFFF;
    c.dwSupport = MIDICAPS_VOLUME;
    memcpy(caps, &c, size < sizeof c ? size : sizeof c);
    return MMSYSERR_NOERROR;
}

static unsigned open_device(unsigned dev, uint64_t hmidi, uint64_t callback, uint64_t instance, unsigned flags,
                            struct bcd_midi_notify *notify, uint64_t *tag)
{
    unsigned i;
    char why[160];
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    pthread_mutex_lock(&g_lock);
    if (g_loaded <= 0) { pthread_mutex_unlock(&g_lock); return MMSYSERR_NODRIVER; }
    for (i = 0; i < MAX_HANDLES && g_handles[i].used; i++) {}
    if (i == MAX_HANDLES) { pthread_mutex_unlock(&g_lock); return MMSYSERR_NODRIVER; }
    if (!g_synth_up) {
        why[0] = 0;
        if (bcd_synth_open(why, sizeof why) != 0) {
            say("[midi] open failed: %s", why[0] ? why : "the synthesizer did not start");
            pthread_mutex_unlock(&g_lock);
            return MMSYSERR_ERROR;
        }
        g_synth_up = 1;
        memset(&g_session, 0, sizeof g_session);
        g_first_note_said = 0;
        clock_gettime(CLOCK_MONOTONIC, &g_up_since);
        bcd_synth_volume((float)((g_volume & 0xFFFFu) > (g_volume >> 16) ? (g_volume & 0xFFFFu) : (g_volume >> 16)) / 65535.0f);
    }
    g_handles[i].used = 1;
    g_handles[i].hmidi = hmidi;
    g_handles[i].callback = callback;
    g_handles[i].instance = instance;
    g_handles[i].flags = (flags & CALLBACK_TYPEMASK) >> 16;   /* MODM_OPEN also carries MIDI_IO_*: not a reason to refuse */
    g_open++;
    g_stats.opens++;
    g_session.opens++;
    g_running = 0;
    if (tag) *tag = HANDLE_TAG | (i + 1u);
    fill_notify(notify, &g_handles[i], MM_MOM_OPEN, 0, 0);
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_open(unsigned dev, uint64_t hmidi, uint64_t callback, uint64_t instance, unsigned flags,
                           struct bcd_midi_notify *notify)
{
    return open_device(dev, hmidi, callback, instance, flags, notify, NULL);
}

/* Closes the handle `user` names (the dwDriverInstance winmm kept); a value that is not ours closes the newest. */
static unsigned close_device(unsigned dev, uint64_t user, struct bcd_midi_notify *notify)
{
    struct handle *h;
    struct handle copy;
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    pthread_mutex_lock(&g_lock);
    h = handle_for(user);
    if (!h) { pthread_mutex_unlock(&g_lock); return MMSYSERR_NOERROR; }   /* closed already: nothing to undo */
    copy = *h;
    h->used = 0;
    if (g_open > 0) g_open--;
    g_stats.closes++;
    g_session.closes++;
    fill_notify(notify, &copy, MM_MOM_CLOSE, 0, 0);
    if (g_open == 0) close_synth_locked();
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_close(unsigned dev, struct bcd_midi_notify *notify)
{
    return close_device(dev, 0, notify);
}

static void channel_message(uint8_t st, uint8_t d1, uint8_t d2)
{
    switch (st & 0xF0) {
    case 0x90:
        if (d2) {
            g_stats.notes++; g_session.notes++;
            if (!g_first_note_said) {
                g_first_note_said = 1;
                say("[midi] first note: channel %u, key %u, velocity %u", (unsigned)(st & 0x0F), (unsigned)d1, (unsigned)d2);
            }
        } else { g_stats.other_channel++; g_session.other_channel++; }
        break;
    case 0xB0: g_stats.controllers++; g_session.controllers++; break;
    case 0xC0: g_stats.program_changes++; g_session.program_changes++; break;
    default:   g_stats.other_channel++; g_session.other_channel++; break;
    }
    bcd_synth_short(st, d1, (st & 0xF0) == 0xC0 || (st & 0xF0) == 0xD0 ? 0 : d2);
}

static void silence_all(void)
{
    unsigned ch;
    for (ch = 0; ch < 16; ch++) {
        bcd_synth_short((uint8_t)(0xB0 | ch), 123, 0);   /* all notes off */
        bcd_synth_short((uint8_t)(0xB0 | ch), 120, 0);   /* all sound off */
        bcd_synth_short((uint8_t)(0xB0 | ch), 121, 0);   /* reset all controllers */
    }
}

unsigned bcd_midi_out_data(unsigned dev, uint32_t data)
{
    uint8_t b0 = (uint8_t)(data & 0xFF), b1, b2;
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    pthread_mutex_lock(&g_lock);
    if (!g_synth_up) { g_stats.dropped++; pthread_mutex_unlock(&g_lock); return MMSYSERR_NOERROR; }
    if (b0 & 0x80) {
        b1 = (uint8_t)((data >> 8) & 0x7F);
        b2 = (uint8_t)((data >> 16) & 0x7F);
        if (b0 < 0xF0) g_running = b0;
        else if (b0 <= 0xF7) g_running = 0;
    } else if (g_running) {
        b0 = g_running;
        b1 = (uint8_t)(data & 0x7F);
        b2 = (uint8_t)((data >> 8) & 0x7F);
        g_stats.running_status++; g_session.running_status++;
    } else {
        g_stats.dropped++; g_session.dropped++;   /* data bytes with no status to belong to */
        pthread_mutex_unlock(&g_lock);
        return MMSYSERR_NOERROR;
    }
    if (b0 >= 0xF0) {
        if (b0 == 0xFF) silence_all();             /* system reset */
        /* clock, active sensing, song position and the like: nothing for a synthesizer to do */
    } else {
        channel_message(b0, b1, b2);
    }
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_prepare(uint32_t *header_flags, int unprepare)
{
    if (!header_flags) return MMSYSERR_INVALPARAM;
    if (!unprepare) {
        if (*header_flags & MHDR_PREPARED) return MMSYSERR_NOERROR;
        *header_flags |= MHDR_PREPARED;
        *header_flags &= ~(MHDR_DONE | MHDR_INQUEUE);
        return MMSYSERR_NOERROR;
    }
    if (!(*header_flags & MHDR_PREPARED)) return MMSYSERR_NOERROR;
    if (*header_flags & MHDR_INQUEUE) return MIDIERR_STILLPLAYING;
    *header_flags &= ~MHDR_PREPARED;
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_long_data(unsigned dev, const uint8_t *data, uint32_t length, uint32_t *header_flags,
                                uint64_t header, struct bcd_midi_notify *notify)
{
    struct handle copy;
    struct handle *h;
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    if (!data || !header_flags) return MMSYSERR_INVALPARAM;
    if (!(*header_flags & MHDR_PREPARED)) return MIDIERR_UNPREPARED;
    if (*header_flags & MHDR_INQUEUE) return MIDIERR_STILLPLAYING;
    pthread_mutex_lock(&g_lock);
    if (g_synth_up) {
        if (length >= 2 && data[0] == 0xF0 && data[length - 1] == 0xF7 && length <= (1u << 20)) {
            bcd_synth_sysex(data, length);
            g_stats.sysex++; g_session.sysex++;
        } else {
            g_stats.bad_sysex++; g_session.bad_sysex++;   /* not a whole F0..F7 message: a synthesizer would wait for the rest forever */
        }
    } else {
        g_stats.dropped++; g_session.dropped++;
    }
    g_running = 0;                                   /* a system exclusive message ends running status */
    *header_flags &= ~(MHDR_INQUEUE);
    *header_flags |= MHDR_DONE;
    h = handle_for(0);
    memset(&copy, 0, sizeof copy);
    if (h) copy = *h;
    fill_notify(notify, h ? &copy : NULL, MM_MOM_DONE, header, 0);
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_reset(unsigned dev)
{
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    pthread_mutex_lock(&g_lock);
    if (g_synth_up) silence_all();
    g_running = 0;
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_get_volume(unsigned dev, uint32_t *volume)
{
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    if (!volume) return MMSYSERR_INVALPARAM;
    pthread_mutex_lock(&g_lock);
    *volume = g_volume;
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

unsigned bcd_midi_out_set_volume(unsigned dev, uint32_t volume)
{
    unsigned lo = volume & 0xFFFFu, hi = volume >> 16;
    if (dev != 0) return MMSYSERR_BADDEVICEID;
    pthread_mutex_lock(&g_lock);
    g_volume = volume;
    /* one master gain: the louder side (the CoreAudio driver in Wine does the same) */
    if (g_synth_up) bcd_synth_volume((float)(lo > hi ? lo : hi) / 65535.0f);
    pthread_mutex_unlock(&g_lock);
    return MMSYSERR_NOERROR;
}

void bcd_midi_stats(struct bcd_midi_stats *out)
{
    pthread_mutex_lock(&g_lock);
    *out = g_stats;
    pthread_mutex_unlock(&g_lock);
}

void bcd_midi_test_reset(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_synth_up) bcd_synth_close();
    g_synth_up = 0;
    g_loaded = 0;
    g_open = 0;
    g_running = 0;
    g_volume = 0xFFFFFFFFu;
    memset(g_handles, 0, sizeof g_handles);
    memset(&g_stats, 0, sizeof g_stats);
    memset(&g_session, 0, sizeof g_session);
    memset(&g_quit_until, 0, sizeof g_quit_until);
    g_first_note_said = g_said_off = g_said_nobank = g_said_ready = 0;
    pthread_mutex_unlock(&g_lock);
}

/* ------------------------------------------------------------------ the argument blocks */

static void write_notify64(void *dst, const struct bcd_midi_notify *n)
{
    struct notify_ctx64 *c = dst;
    if (!c) return;
    if (!n->send) { c->send_notify = 0; return; }
    c->send_notify = 1;
    c->dev_id = (uint16_t)n->dev_id;
    c->msg = (uint16_t)n->msg;
    c->param_1 = n->param_1;
    c->param_2 = n->param_2;
    c->callback = n->callback;
    c->flags = n->flags;
    c->device = n->device;
    c->instance = n->instance;
}

static void write_notify32(void *dst, const struct bcd_midi_notify *n)
{
    struct notify_ctx32 *c = dst;
    if (!c) return;
    if (!n->send) { c->send_notify = 0; return; }
    c->send_notify = 1;
    c->dev_id = (uint16_t)n->dev_id;
    c->msg = (uint16_t)n->msg;
    c->param_1 = (uint32_t)n->param_1;
    c->param_2 = (uint32_t)n->param_2;
    c->callback = (uint32_t)n->callback;
    c->flags = n->flags;
    c->device = (uint32_t)n->device;
    c->instance = (uint32_t)n->instance;
}

/* One MIDI-out message in either width. `wide`: the 64-bit block. All arguments are decoded into plain
 * values first; the structures behind param_1 are read in their width. */
struct out_args {
    int wide;
    unsigned dev_id, msg;
    uint64_t user, param_1, param_2;
};

static unsigned out_dispatch(const struct out_args *a, uint64_t *new_instance, struct bcd_midi_notify *notify)
{
    switch (a->msg) {
    case DRVM_INIT:
    case DRVM_EXIT:
    case DRVM_ENABLE:
    case DRVM_DISABLE:
        return MMSYSERR_NOERROR;
    case MODM_GETNUMDEVS:
        return bcd_midi_out_num_devs();
    case MODM_GETDEVCAPS: {
        void *caps = a->wide ? (void *)(uintptr_t)a->param_1 : wow_host((uint32_t)a->param_1);
        return bcd_midi_out_dev_caps(a->dev_id, caps, (unsigned)a->param_2);
    }
    case MODM_OPEN: {
        const uint8_t *desc = a->wide ? (const uint8_t *)(uintptr_t)a->param_1 : (const uint8_t *)wow_host((uint32_t)a->param_1);
        uint64_t hmidi, callback, instance;
        unsigned r;
        if (!desc) return MMSYSERR_INVALPARAM;
        if (a->wide) {   /* MIDIOPENDESC: HMIDI, DWORD_PTR dwCallback, DWORD_PTR dwInstance, ... */
            memcpy(&hmidi, desc, 8); memcpy(&callback, desc + 8, 8); memcpy(&instance, desc + 16, 8);
        } else {
            uint32_t v;
            memcpy(&v, desc, 4); hmidi = v;
            memcpy(&v, desc + 4, 4); callback = v;
            memcpy(&v, desc + 8, 4); instance = v;
        }
        r = open_device(a->dev_id, hmidi, callback, instance, (unsigned)a->param_2, notify, new_instance);
        return r;
    }
    case MODM_CLOSE:
        return close_device(a->dev_id, a->user, notify);
    case MODM_PREPARE:
    case MODM_UNPREPARE: {
        uint8_t *hdr = a->wide ? (uint8_t *)(uintptr_t)a->param_1 : (uint8_t *)wow_host((uint32_t)a->param_1);
        unsigned min = a->wide ? HDR64_DWOFFSET : HDR32_DWOFFSET;
        void *lp;
        if (!hdr || a->param_2 < min) return MMSYSERR_INVALPARAM;
        if (a->wide) memcpy(&lp, hdr, sizeof lp); else { uint32_t v; memcpy(&v, hdr, 4); lp = (void *)(uintptr_t)v; }
        if (!lp) return MMSYSERR_INVALPARAM;
        return bcd_midi_out_prepare((uint32_t *)(hdr + (a->wide ? 24 : 16)), a->msg == MODM_UNPREPARE);
    }
    case MODM_DATA:
        return bcd_midi_out_data(a->dev_id, (uint32_t)a->param_1);
    case MODM_LONGDATA: {
        uint8_t *hdr = a->wide ? (uint8_t *)(uintptr_t)a->param_1 : (uint8_t *)wow_host((uint32_t)a->param_1);
        const uint8_t *data;
        uint32_t length;
        if (!hdr) return MMSYSERR_INVALPARAM;
        if (a->wide) {   /* MIDIHDR: LPSTR lpData, DWORD dwBufferLength, DWORD dwBytesRecorded, DWORD_PTR dwUser, DWORD dwFlags */
            uint64_t p;
            memcpy(&p, hdr, 8); data = (const uint8_t *)(uintptr_t)p;
            memcpy(&length, hdr + 8, 4);
        } else {
            uint32_t p;
            memcpy(&p, hdr, 4); data = (const uint8_t *)wow_host(p);
            memcpy(&length, hdr + 4, 4);
        }
        return bcd_midi_out_long_data(a->dev_id, data, length, (uint32_t *)(hdr + (a->wide ? 24 : 16)), a->param_1, notify);
    }
    case MODM_RESET:
        return bcd_midi_out_reset(a->dev_id);
    case MODM_GETVOLUME: {
        uint32_t *out = a->wide ? (uint32_t *)(uintptr_t)a->param_1 : (uint32_t *)wow_host((uint32_t)a->param_1);
        return bcd_midi_out_get_volume(a->dev_id, out);
    }
    case MODM_SETVOLUME:
        return bcd_midi_out_set_volume(a->dev_id, (uint32_t)a->param_1);
    default:
        return MMSYSERR_NOTSUPPORTED;   /* MODM_CACHEPATCHES and the like */
    }
}

static int out_message(const struct out_args *a, uint32_t *err, void *notify_dst, int wide)
{
    struct bcd_midi_notify n;
    uint64_t instance = 0;
    unsigned r;
    memset(&n, 0, sizeof n);
    r = out_dispatch(a, &instance, &n);
    if (r == MMSYSERR_NOERROR && a->msg == MODM_OPEN && instance && a->user) {
        /* winmm gave the address of its dwDriverInstance; what is stored there comes back as `user`. */
        if (wide) { uint64_t v = instance; memcpy((void *)(uintptr_t)a->user, &v, 8); }
        else { uint32_t v = (uint32_t)instance; void *p = wow_host((uint32_t)a->user); if (p) memcpy(p, &v, 4); }
    }
    if (err) *err = r;
    if (wide) write_notify64(notify_dst, &n); else write_notify32(notify_dst, &n);
    return 0;
}

int bcd_midi_out_message64(void *args)
{
    struct params64 *p = args;
    struct out_args a = { 1, p->dev_id, p->msg, p->user, p->param_1, p->param_2 };
    return out_message(&a, p->err, p->notify, 1);
}

int bcd_midi_out_message32(void *args)
{
    struct params32 *p = args;
    struct out_args a = { 0, p->dev_id, p->msg, p->user, p->param_1, p->param_2 };
    return out_message(&a, (uint32_t *)wow_host(p->err), wow_host(p->notify), 0);
}

/* MIDI in: no input device. winmm asks for the count and gets 0; the rest is "not supported". */
static unsigned in_dispatch(unsigned msg)
{
    switch (msg) {
    case DRVM_INIT:
    case DRVM_EXIT:
    case DRVM_ENABLE:
    case DRVM_DISABLE:
    case MIDM_GETNUMDEVS:
        return 0;
    default:
        return MMSYSERR_NOTSUPPORTED;
    }
}

int bcd_midi_in_message64(void *args)
{
    struct params64 *p = args;
    if (p->err) *p->err = in_dispatch(p->msg);
    if (p->notify) *(int32_t *)p->notify = 0;
    return 0;
}

int bcd_midi_in_message32(void *args)
{
    struct params32 *p = args;
    uint32_t *err = wow_host(p->err);
    void *notify = wow_host(p->notify);
    if (err) *err = in_dispatch(p->msg);
    if (notify) *(int32_t *)notify = 0;
    return 0;
}

/* Auxiliary devices (CD volume and the like): none. */
static unsigned aux_dispatch(unsigned msg)
{
    switch (msg) {
    case DRVM_INIT:
    case DRVM_EXIT:
    case DRVM_ENABLE:
    case DRVM_DISABLE:
    case AUXDM_GETNUMDEVS:
        return 0;
    default:
        return MMSYSERR_NOTSUPPORTED;
    }
}

int bcd_midi_aux_message64(void *args)
{
    struct aux64 *p = args;
    if (p->err) *p->err = aux_dispatch(p->msg);
    return 0;
}

int bcd_midi_aux_message32(void *args)
{
    struct aux32 *p = args;
    uint32_t *err = wow_host(p->err);
    if (err) *err = aux_dispatch(p->msg);
    return 0;
}
