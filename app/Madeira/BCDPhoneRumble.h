// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDPhoneRumble.h
//  Madeira
//
//  The phone itself shaking with a game's rumble (round 604, B9). A game that rumbles the pad in XInput slot 0 while no physical controller
//  is paired (the on-screen controller is player 1) has nowhere for it to go; with the in-game menu's "Phone vibration" switch on, this
//  plays it on the phone's haptic engine, one continuous event whose strength follows the game's motors, exactly as PadOutput.m does for
//  a physical pad. Off, which is how every session starts, nothing here exists: no engine is made and no call does more than read a flag.
//
//  Plain C entry points. All of them run on the main thread (PadOutput.m's pass runs there).
//

#ifndef BCD_PHONE_RUMBLE_H
#define BCD_PHONE_RUMBLE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when this device has a haptic engine (an iPhone; an iPad has none).
int bcd_phone_rumble_available(void);

/// The player's switch. Turning it off stops a running rumble and lets the engine go.
void bcd_phone_rumble_set_enabled(int on);
int bcd_phone_rumble_enabled(void);

/// The game's two motors (0...1) for player 1, while no physical pad is paired. (0, 0) stops it.
void bcd_phone_rumble_push(float low, float high);

/// The app resigns active, the menu opens or the session ends: stop at once and keep the setting.
void bcd_phone_rumble_stop(void);

#ifdef __cplusplus
}
#endif

#endif
