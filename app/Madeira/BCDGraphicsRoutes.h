// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDGraphicsRoutes.h
//
//  Which DLL a 32-bit game gets for an old Direct3D or DirectDraw, decided at session start (round 602, 2026-10-25).
//
//  Wine's d3d8.dll and ddraw.dll draw through wined3d, whose only 3D backend is OpenGL, and a phone has none. Two DLLs built from
//  third-party sources take their place, for a game whose own file asks for them:
//
//    env.MADEIRA_D3D8 = d3d9    C:\windows\syswow64\d3d8.dll  -> d3d8to9.dll   crosire's d3d8to9 (BSD 2-Clause): Direct3D 8 on Direct3D 9,
//                                                                                which is DXMT's in a 32-bit session
//    env.MADEIRA_DDRAW = cnc    C:\windows\syswow64\ddraw.dll -> cnc-ddraw.dll  FunkyFr3sh's cnc-ddraw (MIT): DirectDraw drawn through
//                                                                                Direct3D 9 (DXMT) or GDI, with scaling and full screen
//
//  The links are made after the bridge relinked the i386 farm (every file of the bundle's i386-windows folder), so a session without the
//  line has Wine's DLLs again: dropping the line is enough. Nothing is linked for another value, and a missing DLL leaves Wine's in place
//  and says so. Pure C, compiled by tests/host/check-d3d8-to-d3d9.py.

#ifndef BCD_GRAPHICS_ROUTES_H
#define BCD_GRAPHICS_ROUTES_H

#include <stddef.h>

typedef struct BCDWowRoute {
    const char *env;      /* the variable of the game's own file, MADEIRA_D3D8 */
    const char *value;    /* the one value that asks for it: d3d9 */
    const char *target;   /* the DLL a 32-bit program loads from syswow64: d3d8.dll */
    const char *source;   /* the DLL of the bundle's i386 farm that takes its place: d3d8to9.dll */
    const char *what;     /* a few words for the log */
} BCDWowRoute;

extern const BCDWowRoute bcd_wow_routes[];
extern const int bcd_wow_route_count;

/* Applies one route for the value `envValue` of its variable (NULL: unset). Returns 1 when syswow64Dir/target now links to
 * i386Dir/source, 0 when this route is not asked for (nothing touched), -1 when it is asked for and cannot be done (the DLL is not in the
 * bundle, or the link failed; Wine's DLL stays). `line` receives the log line (with its newline) for 1 and -1. */
int bcd_wow_route_apply(const BCDWowRoute *route, const char *envValue, const char *syswow64Dir, const char *i386Dir, char *line, size_t lineSize);

/* Every route, with its variable read from the environment; each line goes to file descriptor `fd`. Returns the number linked. */
int bcd_wow_routes_apply(const char *syswow64Dir, const char *i386Dir, int fd);

#endif
