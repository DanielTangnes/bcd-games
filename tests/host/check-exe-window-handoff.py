#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""env.MADEIRA_EXE_WINDOW_HANDOFF: the fixed base goes on to a relaunched copy of the same program (virtual_ios.c, process_ios.c).

A program whose main image has stripped relocations and starts a copy of itself before it exits (a launcher relaunching
itself) could never start the copy: both pseudo-processes share one address space, the copy mapped while the first
instance still held the fixed base, and it failed with c0000018. Two defects were behind it:
  - ios_exe_win_commit_claim compared the claim with the unrounded SizeOfImage, while the claim had been noted with the
    host-page-rounded size, so an image whose size is not a multiple of 16 KB stayed CLAIMING for the session: never OWNED,
    never retired at exit, never handed on;
  - nothing made the copy wait for the owner's exit handoff, and NtCreateUserProcess in the owner waited for the copy's
    start-up, which cannot finish until the owner exits.

It changes how the window's claim is kept for every fixed-base program, so in BCD it is OFF unless
env.MADEIRA_EXE_WINDOW_HANDOFF = 1 (the game's own file). Checks:
  1. ios_exe_win_commit_claim, cut out of virtual_ios.c with the window code and run on the host: an image whose size is not
     a multiple of 16 KB stays CLAIMING with the switch off (as before) and becomes OWNED with it on; an aligned image is
     OWNED either way;
  2. the switch is read once and only "1" turns it on; the wait for the owner's exit (ios_exe_win_wait_for_handoff) returns
     at once without it, is called from virtual_map_module only, and only for a 64-bit fixed-base main image;
  3. NtCreateUserProcess keeps its plain NtWaitForSingleObject(process_info, FALSE, NULL) without the switch, and polls
     every 50 ms (to return when the new process waits for this one) with it.
Needs python3 and a C compiler.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / "build/ntdll-unix/virtual_ios.c").read_text()
proc = (root / "build/ntdll-unix/process_ios.c").read_text()
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + str(detail)) if detail and not cond else ""))
    ok = ok and bool(cond)


start = src.index("static uint64_t ios_exe_win_base, ios_exe_win_size;")
commit = src.index("void ios_exe_win_commit_claim( void *base, size_t size, int mapped )\n{")
chunk = src[start:src.index("\n}\n", commit) + 3]

harness = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/mman.h>
typedef int kern_return_t;
typedef uintptr_t vm_address_t;
typedef size_t vm_size_t;
#define KERN_SUCCESS 0
#define ROUND_SIZE(addr, size, mask) ((((size_t)(size)) + ((uintptr_t)(addr) & (mask)) + (mask)) & ~(size_t)(mask))
static const uintptr_t host_page_mask = 0x3fff;
static unsigned mach_task_self(void) { return 1; }
static kern_return_t vm_deallocate(unsigned task, vm_address_t a, vm_size_t s) { (void)task; (void)a; (void)s; return KERN_SUCCESS; }
static void ios_va_release_note(void) {}
static char out[1 << 16]; static size_t outn;
static int fake_dprintf(int fd, const char *f, ...)
{ va_list ap; int w; (void)fd; va_start(ap, f); w = vsnprintf(out + outn, sizeof out - outn, f, ap); va_end(ap); if (w > 0) outn += w; return w; }
#define dprintf fake_dprintf
''' + chunk + r'''
#undef dprintf
static void *anon_mmap_tryfixed(void *start, size_t size, int prot, int flags) { (void)size; (void)prot; (void)flags; return start; }
#define WIN ((const void *)0x140000000ull)
static int fail(const char *what) { printf("%s\nFAIL: %s\n", out, what); return 1; }

int main(int argc, char **argv)
{
    const char *s = argc > 1 ? argv[1] : "";
    setenv("WINE_IOS_EXE_WINDOW", "140000000:8000000", 1);
    /* an image of 0x7526000 bytes: the claim is noted with the host-page-rounded 0x7528000 (map_fixed_area), the image
     * view commits with SizeOfImage */
    if (ios_exe_win_claim(WIN, 0x7528000) != 1) return fail("the claim did not get the window");
    ios_exe_win_commit_claim((void *)WIN, 0x7526000, 1);
    if (!strcmp(s, "off") || !strcmp(s, "zero"))
    {
        if (ios_exewin_st != IOS_EXEWIN_CLAIMING) return fail("without the switch an unaligned image no longer stays CLAIMING (the old behaviour)");
        printf("PASS: switch %s: an image whose size is not a multiple of 16 KB stays CLAIMING, as before\n", s);
        return 0;
    }
    if (!strcmp(s, "on"))
    {
        if (ios_exewin_st != IOS_EXEWIN_OWNED) return fail("with the switch the unaligned image did not become OWNED");
        printf("PASS: switch on: the same image becomes OWNED\n");
        return 0;
    }
    return 2;
}
'''

cc = os.environ.get("CC", "cc")
with tempfile.TemporaryDirectory(prefix="madeira-exe-handoff-") as directory:
    c = Path(directory) / "h.c"
    exe = Path(directory) / "h"
    c.write_text(harness)
    b = subprocess.run([cc, "-std=gnu11", "-Wall", "-Werror", "-Wno-unused-function", "-Wno-unused-variable", "-Wno-misleading-indentation",
                        "-fsanitize=address,undefined", "-o", str(exe), str(c), "-lpthread"], capture_output=True, text=True)
    check("the window code builds on the host", b.returncode == 0, b.stdout + b.stderr)
    if b.returncode == 0:
        for scenario, value in (("off", None), ("zero", "0"), ("on", "1")):
            env = {k: v for k, v in os.environ.items() if k not in ("MADEIRA_EXE_WINDOW_HANDOFF", "MADEIRA_FIXED_BASE_GUARD")}
            if value is not None:
                env["MADEIRA_EXE_WINDOW_HANDOFF"] = value
            r = subprocess.run([str(exe), scenario], capture_output=True, text=True, env=env)
            check("MADEIRA_EXE_WINDOW_HANDOFF=%r" % value, r.returncode == 0 and "PASS" in r.stdout, r.stdout + r.stderr)

# ---- the source
enabled = src[src.index("static int ios_exe_win_handoff_enabled(void)"):]
enabled = enabled[:enabled.index("\n}\n")]
check("the switch is read once and only '1' turns it on", src.count('getenv( "MADEIRA_EXE_WINDOW_HANDOFF" )') == 1 and "enabled = (e && e[0] == '1');" in enabled)
check("the claim rounds its size only with the switch", "if (ios_exe_win_handoff_enabled()) size = ROUND_SIZE( 0, size, host_page_mask );" in src)
wait = src[src.index("static void ios_exe_win_wait_for_handoff( const struct pe_image_info *info )"):]
wait = wait[:wait.index("\n}\n")]
check("the wait returns at once without the switch, and for anything but a 64-bit fixed-base main image",
      "if (!wait_ms || !ios_exe_win_handoff_enabled()) return;" in wait and "IMAGE_FILE_RELOCS_STRIPPED" in wait
      and "IMAGE_FILE_DLL" in wait and "is_machine_64bit( info->machine )" in wait)
check("the wait is called once, from the main image's mapping", src.count("ios_exe_win_wait_for_handoff( image_info );") == 1)
check("the owner's NtCreateUserProcess keeps the plain wait without the switch, and polls with it",
      "if (!ios_exe_win_handoff_on()) NtWaitForSingleObject( process_info, FALSE, NULL );\n        else\n        while (NtWaitForSingleObject( process_info, FALSE, &poll ) == STATUS_TIMEOUT)" in proc
      and "int ios_exe_win_handoff_on( void )" in src)
check("the wait time is a number of milliseconds, 10 s by default", 'getenv( "MADEIRA_EXE_WINDOW_WAIT_MS" )' in src and "atoi( e ) : 10000" in src)
check("no recommended list and no auto-tune rule sets it", "MADEIRA_EXE_WINDOW_HANDOFF" not in (root / "recommended/recommendations.json").read_text()
      and "MADEIRA_EXE_WINDOW_HANDOFF" not in (root / "build/tools/autotune_rules.py").read_text())

print("PASS: exe window handoff" if ok else "FAIL: exe window handoff")
sys.exit(0 if ok else 1)
