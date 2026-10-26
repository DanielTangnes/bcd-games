// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDPhoneRumble.m
//  Madeira
//
//  See BCDPhoneRumble.h. One CHHapticEngine for the device, one continuous event of 30 s whose intensity control follows the motors; a plain
//  pattern player, started again before the event ends, as PadOutput.m does for the controllers (the advanced player breaks on some devices).
//  The engine is made when the first rumble arrives and dropped when the switch goes off or the engine stops (the system stops it when the
//  app leaves the front); it is made again on demand with a back-off after a failure. The log says what happened, at most a few lines.

#import "BCDPhoneRumble.h"
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>

#define GIVE_UP 6

static int g_enabled;
static CHHapticEngine *g_engine;
static id<CHHapticPatternPlayer> g_player;
static BOOL g_playing;
static CFAbsoluteTime g_startedAt;
static CFAbsoluteTime g_retryAt;
static float g_sent = -1;
static unsigned g_failures;
static unsigned g_logged;

int bcd_phone_rumble_available(void)
{
    static int known = -1;
    if (known < 0) known = CHHapticEngine.capabilitiesForHardware.supportsHaptics ? 1 : 0;
    return known;
}

int bcd_phone_rumble_enabled(void) { return g_enabled; }

static void drop_engine(void)
{
    CHHapticEngine *engine = g_engine;
    g_engine = nil;          // before stopping: its stoppedHandler then finds nothing to restart
    g_player = nil;
    g_playing = NO;
    g_sent = -1;
    [engine stopWithCompletionHandler:nil];
}

static void failed(const char *what, NSError *error)
{
    g_failures++;
    double wait = g_failures >= 4 ? 15.0 : (double)(1u << g_failures);
    g_retryAt = CFAbsoluteTimeGetCurrent() + wait;
    if (g_logged++ < 6)
        fprintf(stderr, "[phone-rumble] %s failed (%u in a row): %s%s\n", what, g_failures,
                error ? error.localizedDescription.UTF8String : "no detail", g_failures < GIVE_UP ? "; trying again later" : "; giving up for this session");
}

static id<CHHapticPatternPlayer> player(void)
{
    if (g_player) return g_player;
    if (g_failures >= GIVE_UP || CFAbsoluteTimeGetCurrent() < g_retryAt || !bcd_phone_rumble_available()) return nil;
    NSError *error = nil;
    CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (!engine) { failed("engine", error); return nil; }
    engine.playsHapticsOnly = YES;
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // The system stops the engine when the app leaves the front or audio is interrupted: made again on demand.
            g_engine = nil; g_player = nil; g_playing = NO; g_sent = -1;
            if (g_logged++ < 6) fprintf(stderr, "[phone-rumble] the haptic engine stopped (%ld); it starts again on demand\n", (long)reason);
        });
    };
    engine.resetHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ g_engine = nil; g_player = nil; g_playing = NO; g_sent = -1; });
    };
    if (![engine startAndReturnError:&error]) { failed("engine start", error); return nil; }
    NSArray<CHHapticEventParameter *> *parameters = @[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f],
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.4f],
    ];
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:parameters relativeTime:0 duration:30.0];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    id<CHHapticPatternPlayer> made = pattern ? [engine createPlayerWithPattern:pattern error:&error] : nil;
    if (!made) { [engine stopWithCompletionHandler:nil]; failed("pattern player", error); return nil; }
    if (g_logged++ < 6) fprintf(stderr, "[phone-rumble] ready%s\n", g_failures ? " after failed attempts" : "");
    g_failures = 0;
    g_engine = engine;
    g_player = made;
    g_playing = NO;
    g_sent = -1;
    return made;
}

static void send_level(float level)
{
    CHHapticDynamicParameter *intensity = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                                                          value:level relativeTime:0];
    [g_player sendParameters:@[intensity] atTime:CHHapticTimeImmediate error:nil];
}

void bcd_phone_rumble_stop(void)
{
    if (g_playing) [g_player stopAtTime:CHHapticTimeImmediate error:nil];
    g_playing = NO;
    g_sent = -1;
}

void bcd_phone_rumble_set_enabled(int on)
{
    on = on ? 1 : 0;
    if (on == g_enabled) return;
    g_enabled = on;
    if (!on) {
        bcd_phone_rumble_stop();
        drop_engine();
        g_failures = 0;
    }
}

void bcd_phone_rumble_push(float low, float high)
{
    if (!g_enabled) return;
    float level = fmaxf(low, high);
    if (level < 0.5f / 255.0f) { bcd_phone_rumble_stop(); return; }
    id<CHHapticPatternPlayer> p = player();
    if (!p) return;
    // A plain player does not loop: start it again well before its 30 s event ends.
    if (g_playing && CFAbsoluteTimeGetCurrent() - g_startedAt > 25.0) bcd_phone_rumble_stop();
    if (!g_playing) {
        NSError *error = nil;
        send_level(level);
        if (![p startAtTime:CHHapticTimeImmediate error:&error]) {
            drop_engine();
            failed("player start", error);
            return;
        }
        g_playing = YES;
        g_startedAt = CFAbsoluteTimeGetCurrent();
        send_level(level);
    } else if (level != g_sent) {
        send_level(level);
    }
    g_sent = level;
}
