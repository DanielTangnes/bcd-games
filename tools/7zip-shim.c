// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// 7zip-shim.c: the one function 7-Zip's File Manager needs that BCD's Windows does not have. The File Manager's Help menu calls
// HtmlHelpW (hhctrl.ocx) to open 7-zip.chm. Wine has no 64-bit hhctrl.ocx and BCD ships no .chm file, so linking the import
// would make 7zFM.exe fail to start; this function answers "no window" instead and the Help menu does nothing.
// tools/build-7zip.py links it into 7zFM.exe only; 7-Zip's own source is not changed.
#include <windows.h>

HWND WINAPI HtmlHelpW(HWND parent, LPCWSTR file, UINT command, DWORD_PTR data)
{
    (void)parent;
    (void)file;
    (void)command;
    (void)data;
    return NULL;
}
