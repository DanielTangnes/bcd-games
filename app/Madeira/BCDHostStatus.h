// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDHostStatus.h
//
//  What BCD's system tests (tests/systests, the Start menu's "BCD Tests") need to know about the device and the app, which a
//  Windows program cannot ask: the device, the iOS version, the RAM, the memory limit iOS gives this app, the entitlements,
//  the BCD build. The app writes them once, when the plain Windows desktop session starts, as key=value lines into
//  C:\ProgramData\BCD\host-info.txt of the prefix, and sets MADEIRA_HOST_STATUS to that folder, which switches on the engine's
//  live numbers (build/ntdll-unix/ios_host_status.h writes host-live.txt there).
//
//  Only the plain Windows desktop session gets it (MADEIRA_DESKTOP=1, MADEIRA_EXE explorer.exe, not a BCD Dock session):
//  a game never does, so no game session runs any of this. env.MADEIRA_HOST_STATUS = 0 turns it off.

#ifndef BCD_HOST_STATUS_H
#define BCD_HOST_STATUS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The facts the app has and the session start passes in. Any string may be NULL. */
typedef struct {
    const char *build;            /* CFBundleVersion */
    const char *version;          /* CFBundleShortVersionString */
    unsigned long long pool_cfg_mb;   /* bcd.cfg pool = N, 0 for the default */
    unsigned long long swap_mb;       /* bcd.cfg swap-mb = N, 0 for off */
} bcd_host_facts;

/* Whether this session gets the status: a plain Windows desktop. The arguments are the values of MADEIRA_DESKTOP,
 * MADEIRA_DOCK_SESSION, MADEIRA_EXE and MADEIRA_HOST_STATUS (NULL when unset). */
int bcd_host_status_wanted(const char *desktop, const char *dock_session, const char *exe, const char *host_status);

/* The text of host-info.txt for these facts and this device; the length, or 0 when `cap` is too small. */
size_t bcd_host_info_text(const bcd_host_facts *facts, char *out, size_t cap);

/* Makes <prefix>/drive_c/ProgramData/BCD, writes host-info.txt there and sets MADEIRA_HOST_STATUS to the folder.
 * Returns 1 when the file was written, 0 otherwise (nothing is set then). */
int bcd_host_status_prepare(const char *prefix, const bcd_host_facts *facts);

#ifdef __cplusplus
}
#endif

#endif /* BCD_HOST_STATUS_H */
