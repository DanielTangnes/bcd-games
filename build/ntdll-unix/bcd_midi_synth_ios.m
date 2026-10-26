// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's MIDI synthesizer (see bcd_midi_ios.h): Apple's own multi-timbral synthesizer, AUMIDISynth, hosted
// in an AVAudioEngine, loading a General MIDI SoundFont. No Wine header is included here (CoreFoundation
// and Wine's headers disagree about several names), only the functions of bcd_midi_ios.h cross over.
//
// Why AUMIDISynth and not one AVAudioUnitSampler per channel: it has the sixteen parts, bank select, program
// change, the controllers, the pitch wheel and the General MIDI percussion channel (channel 10, bank 128 of
// the SoundFont) already, and one call per MIDI event is all a game's sequencer needs.
//
// What it costs, measured on the SoundFont the app carries (TimGM6mb, 5.7 MB): about 25 MB of memory while
// a game has the device open, none otherwise (the engine is built at the first open and gone at the last
// close), a few milliseconds of CPU per second of music. The AU decodes the whole bank when it starts, which is
// why a big bank (GeneralUser GS, 32 MB, costs about 190 MB) is refused: see max_bank_bytes.
//
// The output is the app's own AVAudioSession (WineProcessBridge.m sets it up before Wine starts); this file
// never changes its category. An engine stopped by an interruption (a call, Siri) or a route change is started
// again when iOS lets it.

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#include "bcd_midi_ios.h"

/* A bank over this size is not used: AUMIDISynth expands it about 4 to 6 times in memory. */
static const off_t max_bank_bytes = 64 * 1024 * 1024;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static AVAudioEngine *g_engine;
static AVAudioUnitMIDIInstrument *g_synth;
static AudioUnit g_au;
static id g_observer_config, g_observer_interrupt;
static char g_bank[1024];
static int g_bank_known;
/* Idle: a game that left the device open and plays nothing (a menu, a pause, a crash that never closed it) does not keep the
 * output rendering. After idle_pause_seconds without a message the engine is paused (memory stays, the audio unit keeps its
 * programs and controllers); the next message starts it again, in a few milliseconds. */
static uint64_t idle_pause_seconds = 60;
static uint64_t g_last_event;        /* mach_absolute_time of the last message */
static int g_paused;
#ifndef BCD_SYNTH_OFFLINE
static dispatch_source_t g_idle_timer;
#endif

#ifdef BCD_SYNTH_OFFLINE
static AVAudioPCMBuffer *g_offline_buffer;
#endif

static double footprint_mb(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return (double)info.phys_footprint / 1048576.0;
}

static double now_ms(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static uint64_t seconds_to_mach(uint64_t seconds)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return seconds * 1000000000ull * tb.denom / tb.numer;
}

/* ------------------------------------------------------------------ the bank */

/* RIFF....sfbk (SoundFont 2) or RIFF....DLS  (DLS): the two kinds the audio unit reads. */
static int bank_looks_right(const char *path, off_t *size)
{
    struct stat st;
    FILE *f;
    unsigned char head[12];
    size_t n;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
    if (st.st_size < 1024 || st.st_size > max_bank_bytes) {
        const char *slash = strrchr(path, '/');
        fprintf(stderr, "[midi] sound bank %s is %lld bytes: not used (it must be between 1 KB and %lld MB, "
                        "because the synthesizer unpacks the whole bank in memory)\n",
                slash ? slash + 1 : path, (long long)st.st_size, (long long)(max_bank_bytes >> 20));
        return 0;
    }
    f = fopen(path, "rb");
    if (!f) return 0;
    n = fread(head, 1, sizeof head, f);
    fclose(f);
    if (n != sizeof head || memcmp(head, "RIFF", 4) != 0) return 0;
    if (memcmp(head + 8, "sfbk", 4) != 0 && memcmp(head + 8, "DLS ", 4) != 0) return 0;
    if (size) *size = st.st_size;
    return 1;
}

static NSString *soundfonts_folder(void)
{
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return dirs.count ? [dirs[0] stringByAppendingPathComponent:@"SoundFonts"] : nil;
}

static int try_bank(const char *path)
{
    if (!path || !path[0] || strlen(path) >= sizeof g_bank) return 0;
    if (!bank_looks_right(path, NULL)) return 0;
    strcpy(g_bank, path);
    return 1;
}

const char *bcd_synth_bank_path(void)
{
    const char *result = NULL;
    pthread_mutex_lock(&g_lock);
    if (!g_bank_known) {
        @autoreleasepool {
            const char *named = getenv("MADEIRA_MIDI_SOUNDFONT");   /* a path, or a file name inside Documents/SoundFonts */
            NSString *folder = soundfonts_folder();
            g_bank[0] = 0;
            if (named && named[0]) {
                if (named[0] == '/') try_bank(named);
                else if (folder) try_bank([[folder stringByAppendingPathComponent:@(named)] fileSystemRepresentation]);
                if (!g_bank[0]) fprintf(stderr, "[midi] env.MADEIRA_MIDI_SOUNDFONT = %s is not a usable sound bank: using the next one\n", named);
            }
            if (!g_bank[0] && folder) {
                NSArray<NSString *> *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil]
                                              sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
                for (NSString *name in names) {
                    NSString *ext = name.pathExtension.lowercaseString;
                    if (![ext isEqualToString:@"sf2"] && ![ext isEqualToString:@"dls"]) continue;
                    if (try_bank([[folder stringByAppendingPathComponent:name] fileSystemRepresentation])) break;
                }
            }
            if (!g_bank[0]) {
                CFURLRef url = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("TimGM6mb"), CFSTR("sf2"), CFSTR("soundfont"));
                if (url) {
                    char path[1024];
                    if (CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path)) try_bank(path);
                    CFRelease(url);
                }
            }
        }
        g_bank_known = 1;
    }
    if (g_bank[0]) result = g_bank;
    pthread_mutex_unlock(&g_lock);
    return result;
}

/* ------------------------------------------------------------------ the engine */

static void fail(char *why, size_t size, const char *text, long code)
{
    if (!why || !size) return;
    if (code) snprintf(why, size, "%s (OSStatus %ld)", text, code);
    else snprintf(why, size, "%s", text);
}

static void restart_engine(const char *because)
{
    NSError *err = nil;
    pthread_mutex_lock(&g_lock);
    if (g_engine && !g_engine.isRunning) {
        if ([g_engine startAndReturnError:&err]) {
            g_paused = 0;
            fprintf(stderr, "[midi] output started again (%s)\n", because);
        }
        else
            fprintf(stderr, "[midi] output could not start again (%s): %s\n", because, err.localizedDescription.UTF8String);
    }
    pthread_mutex_unlock(&g_lock);
}

/* With g_lock held: a message arrived; wake the output if the idle timer paused it. */
static void touch_locked(void)
{
    g_last_event = mach_absolute_time();
    if (g_paused && g_engine) {
        NSError *err = nil;
        if ([g_engine startAndReturnError:&err]) g_paused = 0;
        else fprintf(stderr, "[midi] output could not wake up: %s\n", err.localizedDescription.UTF8String);
    }
}

int bcd_synth_open(char *why, size_t why_size)
{
    int result = -1;
    pthread_mutex_lock(&g_lock);
    if (g_engine) { pthread_mutex_unlock(&g_lock); return 0; }
    pthread_mutex_unlock(&g_lock);
    const char *bank = bcd_synth_bank_path();
    if (!bank) { fail(why, why_size, "no sound bank", 0); return -1; }
    @autoreleasepool {
        double t0 = now_ms(), before = footprint_mb();
        AVAudioEngine *engine = [AVAudioEngine new];
        AudioComponentDescription desc = { kAudioUnitType_MusicDevice, kAudioUnitSubType_MIDISynth,
                                           kAudioUnitManufacturer_Apple, 0, 0 };
        AVAudioUnitMIDIInstrument *synth = [[AVAudioUnitMIDIInstrument alloc] initWithAudioComponentDescription:desc];
        NSError *err = nil;
        if (!synth || !synth.audioUnit) { fail(why, why_size, "Apple's MIDI synthesizer is not available", 0); return -1; }
        [engine attachNode:synth];
        [engine connect:synth to:engine.mainMixerNode format:nil];
#ifdef BCD_SYNTH_OFFLINE
        {
            AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
            if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format
                                maximumFrameCount:4096 error:&err]) {
                fail(why, why_size, "offline rendering did not start", 0);
                return -1;
            }
            g_offline_buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
        }
#endif
        {
            NSURL *url = [NSURL fileURLWithPath:@(bank)];
            CFURLRef cf = (__bridge CFURLRef)url;
            OSStatus st = AudioUnitSetProperty(synth.audioUnit, kMusicDeviceProperty_SoundBankURL, kAudioUnitScope_Global, 0,
                                               &cf, sizeof cf);
            if (st != noErr) { fail(why, why_size, "the synthesizer refused the sound bank", st); return -1; }
        }
        [engine prepare];
        if (![engine startAndReturnError:&err]) {
            /* The session may not be active yet (nothing opened audio so far): ask once, then try again. */
#if TARGET_OS_IOS
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
#endif
            err = nil;
            if (![engine startAndReturnError:&err]) {
                fail(why, why_size, "the audio engine did not start", (long)err.code);
                return -1;
            }
        }
        pthread_mutex_lock(&g_lock);
        g_engine = engine;
        g_synth = synth;
        g_au = synth.audioUnit;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        g_observer_config = [nc addObserverForName:AVAudioEngineConfigurationChangeNotification object:engine queue:nil
                                        usingBlock:^(NSNotification *n) { (void)n; restart_engine("configuration change"); }];
#if TARGET_OS_IOS
        g_observer_interrupt = [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil
                                           usingBlock:^(NSNotification *n) {
            if ([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] != AVAudioSessionInterruptionTypeEnded) return;
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            restart_engine("interruption ended");
        }];
#endif
        g_last_event = mach_absolute_time();
        g_paused = 0;
#ifndef BCD_SYNTH_OFFLINE
        g_idle_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(g_idle_timer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_idle_timer, ^{
            pthread_mutex_lock(&g_lock);
            if (g_engine && !g_paused && g_engine.isRunning && mach_absolute_time() - g_last_event > seconds_to_mach(idle_pause_seconds)) {
                [g_engine pause];
                g_paused = 1;
                fprintf(stderr, "[midi] output paused after %llu s without a MIDI message; the next message starts it again\n", idle_pause_seconds);
            }
            pthread_mutex_unlock(&g_lock);
        });
        dispatch_resume(g_idle_timer);
#endif
        pthread_mutex_unlock(&g_lock);
        {
            const char *slash = strrchr(bank, '/');
            fprintf(stderr, "[midi] synthesizer up: %s, %.0f ms, memory %+.1f MB\n", slash ? slash + 1 : bank,
                    now_ms() - t0, footprint_mb() - before);
        }
        result = 0;
    }
    return result;
}

void bcd_synth_close(void)
{
    @autoreleasepool {
        AVAudioEngine *engine;
        id o1, o2;
        double before = footprint_mb();
        pthread_mutex_lock(&g_lock);
        engine = g_engine;
        o1 = g_observer_config;
        o2 = g_observer_interrupt;
        g_au = NULL;
        g_engine = nil;
        g_observer_config = g_observer_interrupt = nil;
        g_paused = 0;
#ifndef BCD_SYNTH_OFFLINE
        if (g_idle_timer) { dispatch_source_cancel(g_idle_timer); g_idle_timer = nil; }
#endif
        pthread_mutex_unlock(&g_lock);
        if (!engine) return;
        if (o1) [[NSNotificationCenter defaultCenter] removeObserver:o1];
        if (o2) [[NSNotificationCenter defaultCenter] removeObserver:o2];
        [engine stop];
        if (g_synth) [engine detachNode:g_synth];
        pthread_mutex_lock(&g_lock);
        g_synth = nil;
#ifdef BCD_SYNTH_OFFLINE
        g_offline_buffer = nil;
#endif
        pthread_mutex_unlock(&g_lock);
        fprintf(stderr, "[midi] synthesizer down, memory %+.1f MB\n", footprint_mb() - before);
    }
}

/* ------------------------------------------------------------------ events */

void bcd_synth_short(uint8_t status, uint8_t data1, uint8_t data2)
{
    pthread_mutex_lock(&g_lock);
    if (g_au) { touch_locked(); MusicDeviceMIDIEvent(g_au, status, data1, data2, 0); }
    pthread_mutex_unlock(&g_lock);
}

void bcd_synth_sysex(const uint8_t *data, uint32_t length)
{
    pthread_mutex_lock(&g_lock);
    if (g_au) { touch_locked(); MusicDeviceSysEx(g_au, data, length); }
    pthread_mutex_unlock(&g_lock);
}

void bcd_synth_volume(float gain)
{
    pthread_mutex_lock(&g_lock);
    if (g_engine) g_engine.mainMixerNode.outputVolume = gain < 0 ? 0 : (gain > 1 ? 1 : gain);
    pthread_mutex_unlock(&g_lock);
}

#ifdef BCD_SYNTH_TEST_REALTIME
/* The host check's real-time probes (tests/host/midi_idle_host.m): shortens the idle time, tells whether the output runs. */
void bcd_synth_test_set_idle(uint64_t seconds) { idle_pause_seconds = seconds; }
int bcd_synth_test_running(void) { pthread_mutex_lock(&g_lock); int r = g_engine ? (g_engine.isRunning ? 1 : 0) : -1; pthread_mutex_unlock(&g_lock); return r; }
#endif

#ifdef BCD_SYNTH_OFFLINE
/* The host check's way to hear the result: `frames` frames of stereo float (interleaved) rendered now.
 * Returns the frames rendered, or -1. */
int bcd_synth_offline_render(float *interleaved, uint32_t frames)
{
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done > 4096 ? 4096 : frames - done;
        AVAudioEngineManualRenderingStatus st;
        pthread_mutex_lock(&g_lock);
        if (!g_engine || !g_offline_buffer) { pthread_mutex_unlock(&g_lock); return -1; }
        g_offline_buffer.frameLength = n;
        st = [g_engine renderOffline:n toBuffer:g_offline_buffer error:nil];
        if (st != AVAudioEngineManualRenderingStatusSuccess) { pthread_mutex_unlock(&g_lock); return -1; }
        for (uint32_t i = 0; i < n; i++) {
            interleaved[(done + i) * 2] = g_offline_buffer.floatChannelData[0][i];
            interleaved[(done + i) * 2 + 1] = g_offline_buffer.floatChannelData[1][i];
        }
        pthread_mutex_unlock(&g_lock);
        done += n;
    }
    return (int)done;
}
double bcd_synth_offline_footprint_mb(void) { return footprint_mb(); }
#endif
