// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
//  BCDStartMenu.h
//
//  BCD's own entries in the Start menu of Wine's desktop (explorer.exe
//  /desktop=shell): an Explorer entry, the test programs (Direct3D 9, 10, 11
//  and 12, the system tests), the Windows tools, the runtimes installer and 7-Zip. Wine's explorer builds the
//  menu from the .lnk files under C:\ProgramData\Microsoft\Windows\Start Menu
//  (and the user's), so the entries are shortcut files in the prefix.
//
//  An entry names a program of the app's arm64ec-windows or aarch64-windows
//  folder (the session's C:\windows\system32) or of its i386-windows folder (the
//  32-bit set, C:\windows\syswow64), may carry command-line arguments, and sits in
//  a folder of the menu. Tools or tests an older build wrote under a folder or
//  name that no longer exists are removed again when they are still BCD's own.
//
//  A shortcut is written in the binary Shell Link format of Microsoft's
//  [MS-SHLLINK] specification: a header, a LinkInfo block with the target's
//  path, and the description, working folder and arguments as UTF-16 strings.
//  That is the part of the format Wine's shell32 (dlls/shell32/shelllink.c,
//  IPersistStream::Load) reads to start the program; a link with no item ID
//  list is valid, and Wine takes the target from the LinkInfo path.
//
//  The files are BCD's own and the session start keeps them so: each one's
//  description begins with BCD_LNK_MARKER. A file is written only when it is
//  missing, or when it carries the marker and its bytes are outdated; a file
//  without the marker (a person's own shortcut of the same name) is never
//  touched.

#ifndef BCD_STARTMENU_H
#define BCD_STARTMENU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The start of every description BCD writes: how a later start knows a shortcut is BCD's own. */
#define BCD_LNK_MARKER "[BCD] "

/* A shortcut file as bytes. `target` is the program's Windows path ("C:\\windows\\system32\\explorer.exe");
 * `arguments` and `working_dir` may be NULL. The description is BCD_LNK_MARKER followed by `description`.
 * Every string must be plain ASCII and at most 1000 characters. Returns the size, or 0 when the text is
 * not acceptable or `cap` is too small (about 400 bytes plus the strings are needed). The bytes depend
 * only on the arguments, so the same call always gives the same file. */
size_t bcd_lnk_build(const char *target, const char *arguments, const char *working_dir,
                     const char *description, uint8_t *out, size_t cap);

/* Whether a shortcut file is BCD's own: 1 when it is a readable link whose description begins with
 * BCD_LNK_MARKER, 0 when it is a readable link that is not BCD's, -1 when it cannot be read as a link. */
int bcd_lnk_owner(const uint8_t *data, size_t len);

/* One entry of BCD's Start menu. The last two fields may be left out of an initializer (NULL and 0). */
typedef struct {
    const char *folder;       /* below the Start Menu folder, "/" between levels; "" is the top of the menu */
    const char *name;         /* what the menu shows; the file is "<name>.lnk" */
    const char *program;      /* a file of the app's arm64ec-windows or aarch64-windows folder (system32 in a session), else of
                               * its i386-windows folder (the 32-bit set, C:\windows\syswow64); the 64-bit one wins when both
                               * have the name unless BCD_START_X86 is set */
    const char *description;  /* after BCD_LNK_MARKER */
    const char *arguments;    /* the command line after the program's name, plain ASCII, or NULL for none */
    unsigned flags;           /* BCD_START_* */
} bcd_start_entry;

/* The program is the 32-bit one of the name (i386-windows, C:\windows\syswow64), also when a 64-bit program has it too. */
#define BCD_START_X86 1u
/* The entry is written only when Wine Gecko is available in this session: the prefix has it (C:\windows\system32\gecko or syswow64\gecko),
 * or BCD's downloaded files are the session's cache (XDG_CACHE_HOME/wine holds a wine-gecko-*.msi, BCDGecko.swift). Internet Explorer shows
 * nothing without it, and Wine's own installer dialog would have to download it at a crawl. An entry already written stays. */
#define BCD_START_GECKO 2u

extern const bcd_start_entry bcd_start_entries[];
extern const size_t bcd_start_entry_count;
/* The system tests and the Windows tools, a table of their own (round 602) so that the two tables can grow apart. */
extern const bcd_start_entry bcd_start_system_entries[];
extern const size_t bcd_start_system_entry_count;
/* The runtimes folder, 7-Zip and more of Windows' own tools (round 603), a third table. */
extern const bcd_start_entry bcd_start_extra_entries[];
extern const size_t bcd_start_extra_entry_count;

/* More of Wine's own programs (round 604), a fourth table: WordPad, Winefile, the Display and Internet options panels, WineMine, Internet Explorer. */
extern const bcd_start_entry bcd_start_more_entries[];
extern const size_t bcd_start_more_entry_count;

/* Every entry of the four tables, in order: the first table's, then the system table's, then the extra table's, then the more table's. NULL past the end. */
size_t bcd_start_all_count(void);
const bcd_start_entry *bcd_start_all_entry(size_t i);

typedef struct {
    int written;   /* files made or brought up to date */
    int current;   /* BCD's files that were already as they should be */
    int foreign;   /* files without BCD's marker, left alone */
    int missing;   /* entries whose program the app does not carry (or that wait for Wine Gecko, BCD_START_GECKO) */
    int failed;    /* entries that could not be written */
    int no_menu;   /* 1 when the prefix has no public Start Menu folder, so nothing was written */
    int retired;   /* BCD's own files of an earlier build's folder or name that were removed (bcd_start_retired) */
    int x86;       /* entries (written, current or left alone) that start a 32-bit program from syswow64 */
} bcd_start_result;

/* A shortcut an earlier build wrote and this one no longer has: removed when it is a plain file with BCD's marker, and its
 * folder with it when that is empty afterwards. A file of the same name that is not BCD's is never touched. */
typedef struct {
    const char *folder;
    const char *name;
} bcd_start_retired_entry;

extern const bcd_start_retired_entry bcd_start_retired[];
extern const size_t bcd_start_retired_count;

/* Puts BCD's entries into the prefix's public Start Menu folder (<prefix>/drive_c/ProgramData/Microsoft/
 * Windows/Start Menu), which the prefix template provides; a prefix without it gets nothing. `bundle` is
 * the app's folder (its arm64ec-windows and aarch64-windows hold the programs). Only the entries' folders
 * below "Start Menu" are created. */
bcd_start_result bcd_startmenu_install(const char *prefix, const char *bundle);

#ifdef __cplusplus
}
#endif

#endif /* BCD_STARTMENU_H */
