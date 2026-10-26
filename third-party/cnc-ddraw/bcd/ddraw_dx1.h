// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's file, not cnc-ddraw's. cnc-ddraw ships two Microsoft DirectX SDK headers (inc/ddraw.h, inc/d3dcaps.h: "Copyright (C) Microsoft
// Corporation. All Rights Reserved.", no licence grant) that BCD does not copy; tools/build-cnc-ddraw-dll.sh compiles against llvm-mingw's
// own ddraw.h and d3dcaps.h (mingw-w64) instead. The one thing cnc-ddraw uses that mingw-w64's ddraw.h lacks is the DirectX 1 form of the
// DirectDraw capabilities structure, DDCAPS_DX1: the head of DDCAPS_DX3 (the fields of the documented structure up to dwReserved3, 172 bytes), which this
// file declares. Included before cnc-ddraw's own headers with -include.
#ifndef BCD_DDRAW_DX1_H
#define BCD_DDRAW_DX1_H

#include <stddef.h>
#include <windows.h>
#include <ddraw.h>

typedef struct _DDCAPS_DX1 {
    DWORD dwSize;
    DWORD dwCaps;
    DWORD dwCaps2;
    DWORD dwCKeyCaps;
    DWORD dwFXCaps;
    DWORD dwFXAlphaCaps;
    DWORD dwPalCaps;
    DWORD dwSVCaps;
    DWORD dwAlphaBltConstBitDepths;
    DWORD dwAlphaBltPixelBitDepths;
    DWORD dwAlphaBltSurfaceBitDepths;
    DWORD dwAlphaOverlayConstBitDepths;
    DWORD dwAlphaOverlayPixelBitDepths;
    DWORD dwAlphaOverlaySurfaceBitDepths;
    DWORD dwZBufferBitDepths;
    DWORD dwVidMemTotal;
    DWORD dwVidMemFree;
    DWORD dwMaxVisibleOverlays;
    DWORD dwCurrVisibleOverlays;
    DWORD dwNumFourCCCodes;
    DWORD dwAlignBoundarySrc;
    DWORD dwAlignSizeSrc;
    DWORD dwAlignBoundaryDest;
    DWORD dwAlignSizeDest;
    DWORD dwAlignStrideAlign;
    DWORD dwRops[DD_ROP_SPACE];
    DDSCAPS ddsCaps;
    DWORD dwMinOverlayStretch;
    DWORD dwMaxOverlayStretch;
    DWORD dwMinLiveVideoStretch;
    DWORD dwMaxLiveVideoStretch;
    DWORD dwMinHwCodecStretch;
    DWORD dwMaxHwCodecStretch;
    DWORD dwReserved1;
    DWORD dwReserved2;
    DWORD dwReserved3;
} DDCAPS_DX1, *LPDDCAPS_DX1;

// The structure is the head of the DirectX 3 one: a build that gets the sizes wrong would hand a game a caps block of the wrong length.
typedef char bcd_ddcaps_dx1_is_the_head_of_dx3[offsetof(DDCAPS_DX3, dwReserved3) + sizeof(DWORD) == sizeof(DDCAPS_DX1) ? 1 : -1];
typedef char bcd_ddcaps_dx1_is_172_bytes[sizeof(DDCAPS_DX1) == 172 ? 1 : -1];

#endif
