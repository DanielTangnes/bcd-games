// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's MIDI output (round 603). Wine's winmm reaches MIDI through mmdevapi.dll's unix-side table (the
// midi_* slots of audio_null_ios.c). Until now every one of them answered "there is no MIDI", so a game's
// MIDI music was silent. These files answer for one output device, "BCD GM Synthesizer", that plays
// through Apple's own multi-timbral synthesizer (AUMIDISynth, in an AVAudioEngine) and a General MIDI
// SoundFont the app carries (app/Madeira/soundfont/, fetched at build time, never committed).
//
//   bcd_midi_ios.c        the winmm driver side: the message protocol of mmdevapi's unixlib.h for the
//                         64-bit and the 32-bit (WoW64) callers, a running-status parser, a counter for
//                         the log. Plain C, no Wine headers, no Apple frameworks (the host check
//                         tests/host/check-midi-driver.py compiles it against a recording synthesizer).
//   bcd_midi_synth_ios.m  the synthesizer: the engine, the audio unit, the SoundFont, interruptions.
//                         Created when a game opens the device, released when the last one closes it.
//   this header           the few functions between the two, and the ones audio_null_ios.c calls.
//
// Off switch: env.MADEIRA_MIDI = 0 (Settings, a game's own file). Off is what every build before this one
// did: midi_init answers DRV_FAILURE, winmm lists no MIDI device, nothing else changes.

#ifndef BCD_MIDI_IOS_H
#define BCD_MIDI_IOS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ the synthesizer (bcd_midi_synth_ios.m) */

/* The SoundFont to use, or NULL (no bank: no MIDI device). Looked up once and remembered:
 * env.MADEIRA_MIDI_SOUNDFONT (a path, or a name inside Documents/SoundFonts), then the first .sf2/.dls
 * in Documents/SoundFonts (a bank the player put there in Files), then the bank the app carries. */
const char *bcd_synth_bank_path(void);

/* Builds the engine, loads the bank and starts the output. 0: ready; else an error with `why` filled. */
int  bcd_synth_open(char *why, size_t why_size);
/* Stops the output and gives the memory back. Safe to call when nothing is open. */
void bcd_synth_close(void);
/* A channel message (status 0x80..0xEF; data2 is 0 for the two-byte ones). */
void bcd_synth_short(uint8_t status, uint8_t data1, uint8_t data2);
/* A complete system exclusive message, F0 first and F7 last. */
void bcd_synth_sysex(const uint8_t *data, uint32_t length);
/* Master volume, 0...1. */
void bcd_synth_volume(float gain);

/* ------------------------------------------------------------------ the driver (bcd_midi_ios.c) */

/* mmdevapi's DRV_LOAD: 1 when winmm may list the device (MIDI is on and a bank exists). Cheap and safe:
 * nothing is built here. */
int  bcd_midi_init(void);
/* DRV_FREE. Wakes midi_notify_wait so mmdevapi's notify thread ends. */
void bcd_midi_release(void);
/* The notify thread's wait: blocks up to `timeout_ms` or until released. 1: released (quit). */
int  bcd_midi_notify_wait(unsigned timeout_ms);

/* The MIDI-out and MIDI-in message slots of audio_null_ios.c's two tables. `args` is mmdevapi's argument
 * block of the caller's width (struct midi_out_message_params, struct midi_in_message_params). */
int  bcd_midi_out_message64(void *args);
int  bcd_midi_out_message32(void *args);
int  bcd_midi_in_message64(void *args);
int  bcd_midi_in_message32(void *args);
/* aux_message: no auxiliary devices (a count of 0 for AUXDM_GETNUMDEVS, "not supported" for the rest). */
int  bcd_midi_aux_message64(void *args);
int  bcd_midi_aux_message32(void *args);

/* A notification for winmm's DriverCallback in a layout-neutral form. */
struct bcd_midi_notify {
    int send;
    unsigned dev_id, msg, flags;
    uint64_t param_1, param_2, callback, device, instance;
};

/* The same operations with the arguments already decoded (the host check drives these too). Each returns an
 * MMSYSERR_* / MIDIERR_* code; GETNUMDEVS returns the count. */
unsigned bcd_midi_out_num_devs(void);
unsigned bcd_midi_out_dev_caps(unsigned dev, void *caps, unsigned size);   /* a MIDIOUTCAPSW, 84 bytes in both widths */
unsigned bcd_midi_out_open(unsigned dev, uint64_t hmidi, uint64_t callback, uint64_t instance, unsigned flags,
                           struct bcd_midi_notify *notify);
unsigned bcd_midi_out_close(unsigned dev, struct bcd_midi_notify *notify);
unsigned bcd_midi_out_data(unsigned dev, uint32_t data);
unsigned bcd_midi_out_long_data(unsigned dev, const uint8_t *data, uint32_t length, uint32_t *header_flags,
                                uint64_t header, struct bcd_midi_notify *notify);
unsigned bcd_midi_out_prepare(uint32_t *header_flags, int unprepare);
unsigned bcd_midi_out_reset(unsigned dev);
unsigned bcd_midi_out_get_volume(unsigned dev, uint32_t *volume);
unsigned bcd_midi_out_set_volume(unsigned dev, uint32_t volume);

/* The counters the log line at close reports (and the host check reads). */
struct bcd_midi_stats {
    unsigned opens, closes, notes, program_changes, controllers, other_channel, sysex, bad_sysex, running_status, dropped;
};
void bcd_midi_stats(struct bcd_midi_stats *out);
/* Forgets everything (the host check starts every scenario from a clean state). */
void bcd_midi_test_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* BCD_MIDI_IOS_H */
