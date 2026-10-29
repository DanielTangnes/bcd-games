#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""[guest-log] also mirrors a Ren'Py game's own error files (madeira-bcd; logging only).

The mirror (ios_guest_log_mirror in wine/dlls/ntdll/unix/file.c, carried by the Wine pin or added by
tools/patch-wine-guest-log.py) copies lines of a game's own *.log and output_log.txt into the session log.
Ren'Py games (visual novels: Python 2.7 / Ren'Py 6.99 and 7) write their Python errors to traceback.txt,
log.txt, errors.txt and, in older versions, stderr.txt: none of them a *.log. Doki Doki Literature Club (48B1X4,
NTR3Y8, 6AHQMM: builds 600, 611, 622; three devices) and Coming Out on Top (NQZKVF, build 592) all end the same
way, the child process lib\\windows-i686\\<game>.exe calling NtTerminateProcess(exit_code=0xffffffff) right after
pyexpat.pyd, with no message box, no exception and no window: the logs cannot say why because the only place the
reason can be is a file the mirror ignores (tur620/C.md 2.7, tur623).

With the patch those four names count too (any case, any folder; the same default filter of error / fail /
exception / ... lines, the same 64-line budget, the same UTF-8 / UTF-16 decoding and binary refusal; the path is
announced once, "[guest-log] file <path>"). Nothing is written to the game, nothing else is mirrored, and
MADEIRA_GUEST_LOG=0 still turns it off.

Usage: patch-wine-guest-log-renpy.py [path/to/wine/dlls/ntdll/unix/file.c]. Idempotent; fails by name, writing
nothing, if the mirror is not there or its file-name gate moved. It finds the gate by the tail every version of it
shares (the pinned one and the one tools/patch-wine-guest-log-service.py rewrites), so it runs before or after that
patch.
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "wine/dlls/ntdll/unix/file.c"
src = open(path).read()
marker = "madeira-bcd: [guest-log] renpy"
if marker in src:
    print("patch-wine-guest-log-renpy: already patched")
    sys.exit(0)

helper = '''/* ''' + marker + ''' (tools/patch-wine-guest-log-renpy.py): the files a Ren'Py game writes its Python errors to. */
static int ios_guest_log_renpy_file( const char *name )
{
    static const char *const names[] = { "traceback.txt", "stderr.txt", "errors.txt", "log.txt" };
    unsigned int i;

    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        if (!strcasecmp( name, names[i] )) return 1;
    return 0;
}

'''
anchor = "static void ios_guest_log_mirror( int fd, const void *buffer, unsigned int length )\n{\n"
if src.count(anchor) != 1:
    sys.exit("patch-wine-guest-log-renpy: the [guest-log] mirror is not in %s exactly once (anchor: ios_guest_log_mirror, found %d)"
             % (path, src.count(anchor)))
old = 'strcasecmp( name, "output_log.txt" )) goto out;'
new = 'strcasecmp( name, "output_log.txt" ) && !ios_guest_log_renpy_file( name )) goto out;'
if src.count(old) != 1:
    sys.exit("patch-wine-guest-log-renpy: the mirror's file-name gate was not found exactly once in %s (found %d): the mirror moved"
             % (path, src.count(old)))
out = src.replace(anchor, helper + anchor).replace(old, new)
open(path, "w").write(out)
print("patch-wine-guest-log-renpy: applied to " + path)
