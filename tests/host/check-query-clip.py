#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""env.MADEIRA_IMAGE_LOW_ALIAS and env.MADEIRA_QUERY_CLIP (virtual_ios.c): the narrowed form of an image's address, and what VirtualQuery calls free.

Two changes for programs that look at the address space; both OFF in BCD unless the game's own file turns them on, because both
change answers the games that run today have only ever seen the old way:
  - MADEIRA_IMAGE_LOW_ALIAS = 1: a 64-bit image whose preferred base is below 4 GB is mapped above the iOS 4 GB floor, and a
    program that narrows its module handle to 32 bits (Dark Souls Remastered's steamclient64.dll: mov edi,[rbx+0x30];
    movsxd rdx,[rdi+0x3c]) reads nothing. The narrowed form gets a name: [real & 0xffffffff, +size) is registered as a low
    alias of the image (additive: no pointer handed to the guest changes; refused on collision) and retired when the view is
    unmapped. The table holds 48 entries instead of 16 (images take slots too), but only with the switch;
  - MADEIRA_QUERY_CLIP = 1: VirtualQuery reports memory no allocation can land in (below the map floor, host mappings that are
    not Wine views, the JIT pool) as reserved, not MEM_FREE. A walker that looked for a free block near the exe tried to
    allocate at an address iOS can never map.

Checks (the functions are cut out of virtual_ios.c and run on the host):
  1. the switches: unset, empty, 0, anything but 1: off, nothing logged; 1: on; the low-alias table holds 16 entries off, 48 on;
  2. ios_query_first_blocked (the first part of a host range that is not inside a Wine reserved area) and ios_query_pool_fix
     (no answer ends inside the JIT pool; one that reaches into it covers it) on small cases;
  3. the source: the registration, the retire and the clip all return at once without their switch; the query hook runs only
     for a range the view tree calls free; the unmap hook only for an image view; no list and no rule sets either switch.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

R = Path(__file__).resolve().parents[2]
src = (R / "build/ntdll-unix/virtual_ios.c").read_text()
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + str(detail)) if detail and not cond else ""))
    ok = ok and bool(cond)


def cut(signature):
    a = src.index(signature)
    return src[a:src.index("\n}\n", a) + 3]


sw = cut("static int ios_image_lowalias_switch(void)\n{")
cap = "static int ios_lowalloc_capacity(void) { return ios_image_lowalias_switch() ? IOS_LOWALLOC_MAX : IOS_LOWALLOC_PLAIN; }\n"
clip = cut("static int ios_query_clip_enabled(void)\n{")
blocked = cut("static int ios_query_first_blocked( char *lo, char *hi, char **bs, char **be )\n{")
poolfix = cut("static void ios_query_pool_fix( char *base, char *end, char **region_end, BOOL *fake_reserved )\n{")
check("the low-alias table size is chosen by the switch", cap in src and "#define IOS_LOWALLOC_PLAIN 16" in src and "#define IOS_LOWALLOC_MAX   48" in src[:src.index("IOS_LOWALLOC_PLAIN") + 40])

cc = shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
if not cc:
    print("SKIP host run: no C compiler")
else:
    harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define IOS_LOWALLOC_MAX 48
#define IOS_LOWALLOC_PLAIN 16
static int lines;
#define dprintf(fd, ...) (lines++)
struct list { struct list *next, *prev; };
#define LIST_ENTRY(elem, type, field) ((type *)((char *)(elem) - offsetof(type, field)))
#define LIST_FOR_EACH_ENTRY(elem, list, type, field) \
    for ((elem) = LIST_ENTRY((list)->next, type, field); &(elem)->field != (list); (elem) = LIST_ENTRY((elem)->field.next, type, field))
struct reserved_area { struct list entry; void *base; size_t size; unsigned int fex_only; };
static struct list reserved_areas;
static void *ios_jit_rx_base_global, *ios_jit_rw_base_global;
static size_t ios_jit_pool_size_global;
''' + sw + cap + clip + blocked + poolfix + r'''
static int fails;
static void expect(const char *what, int got, int want) { if (got != want) { printf("FAIL %s: got %d want %d\n", what, got, want); fails++; } }
int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp(mode, "switch"))
    {
        int a = ios_image_lowalias_switch(), b = ios_query_clip_enabled();
        printf("%d %d %d %d\n", a, b, ios_lowalloc_capacity(), lines);
        return 0;
    }
    /* reserved areas: [0x1000,0x3000) and [0x5000,0x6000) */
    static struct reserved_area a1 = { {0,0}, (void *)0x1000, 0x2000, 0 }, a2 = { {0,0}, (void *)0x5000, 0x1000, 0 };
    reserved_areas.next = &a1.entry; a1.entry.prev = &reserved_areas; a1.entry.next = &a2.entry;
    a2.entry.prev = &a1.entry; a2.entry.next = &reserved_areas; reserved_areas.prev = &a2.entry;
    char *bs = 0, *be = 0;
    expect("all inside an area", ios_query_first_blocked((char *)0x1000, (char *)0x3000, &bs, &be), 0);
    expect("a part before the area", ios_query_first_blocked((char *)0x800, (char *)0x3000, &bs, &be), 1);
    expect("  starts at lo", (char *)bs == (char *)0x800, 1);
    expect("  ends where the area starts", (char *)be == (char *)0x1000, 1);
    expect("a gap between areas", ios_query_first_blocked((char *)0x1000, (char *)0x6000, &bs, &be), 1);
    expect("  gap start", (char *)bs == (char *)0x3000, 1);
    expect("  gap end", (char *)be == (char *)0x5000, 1);
    expect("a tail past the last area", ios_query_first_blocked((char *)0x5000, (char *)0x9000, &bs, &be), 1);
    expect("  tail", (char *)bs == (char *)0x6000 && (char *)be == (char *)0x9000, 1);
    /* the pool: [0x100000, 0x200000) for RX and [0x300000, 0x400000) for RW */
    ios_jit_rx_base_global = (void *)0x100000; ios_jit_rw_base_global = (void *)0x300000; ios_jit_pool_size_global = 0x100000;
    char *re = (char *)0x180000; BOOL fake = FALSE;
    ios_query_pool_fix((char *)0x80000, (char *)0x400000, &re, &fake);
    expect("a free answer that runs into the pool stops at it", (char *)re == (char *)0x100000 && !fake, 1);
    re = (char *)0x180000; fake = FALSE;
    ios_query_pool_fix((char *)0x100000, (char *)0x400000, &re, &fake);
    expect("a query inside the pool covers all of it", (char *)re == (char *)0x200000 && fake, 1);
    re = (char *)0x2f0000; fake = FALSE;
    ios_query_pool_fix((char *)0x200000, (char *)0x400000, &re, &fake);
    expect("a free answer outside every pool is left alone", (char *)re == (char *)0x2f0000 && !fake, 1);
    re = (char *)0x340000; fake = TRUE;
    ios_query_pool_fix((char *)0x330000, (char *)0x400000, &re, &fake);
    expect("a reserved answer touching the RW alias covers it", (char *)re == (char *)0x400000 && fake, 1);
    if (!fails) printf("harness ok\n");
    return fails != 0;
}
'''
    with tempfile.TemporaryDirectory() as tmp:
        c = os.path.join(tmp, "t.c")
        exe = os.path.join(tmp, "t")
        open(c, "w").write(harness)
        b = subprocess.run([cc, "-std=gnu99", "-Wall", "-Werror", "-Wno-unused-function", "-o", exe, c], capture_output=True, text=True)
        check("the functions build on the host", b.returncode == 0, b.stderr[-2500:])
        if b.returncode == 0:
            def run(mode, **env_extra):
                env = {k: v for k, v in os.environ.items() if k not in ("MADEIRA_IMAGE_LOW_ALIAS", "MADEIRA_QUERY_CLIP")}
                env.update(env_extra)
                return subprocess.run([exe, mode], capture_output=True, text=True, env=env)
            for label, kw in (("unset", {}), ("empty", dict(MADEIRA_IMAGE_LOW_ALIAS="", MADEIRA_QUERY_CLIP="")),
                              ("0", dict(MADEIRA_IMAGE_LOW_ALIAS="0", MADEIRA_QUERY_CLIP="0")),
                              ("true", dict(MADEIRA_IMAGE_LOW_ALIAS="true", MADEIRA_QUERY_CLIP="true"))):
                r = run("switch", **kw)
                check("both switches %s: off, a 16-entry table, nothing logged" % label, r.stdout.split() == ["0", "0", "16", "0"], r.stdout)
            r = run("switch", MADEIRA_IMAGE_LOW_ALIAS="1")
            check("MADEIRA_IMAGE_LOW_ALIAS=1: the alias on (48 entries), the clip still off", r.stdout.split() == ["1", "0", "48", "0"], r.stdout)
            r = run("switch", MADEIRA_QUERY_CLIP="1")
            check("MADEIRA_QUERY_CLIP=1: the clip on (one log line), the alias still off", r.stdout.split() == ["0", "1", "16", "1"], r.stdout)
            r = run("cases")
            check("the pure parts of the clip", r.returncode == 0, r.stdout + r.stderr)

# ---- the source
reg = cut("static void ios_image_lowalias_register( unsigned long long pref_base, unsigned long long real_base,\n                                         unsigned long long size, const char *why )\n{")
ret = cut("static void ios_image_lowalias_retire( unsigned long long real_base )\n{")
check("the registration and the retire return at once without the switch",
      "if (!ios_image_lowalias_enabled()) return;" in reg and "if (!ios_image_lowalias_switch()) return;" in ret)
check("the clip returns at once without the switch", "if (!ios_query_clip_enabled()) return;" in cut("static void ios_query_clip_free( char *base, char **region_start, char **region_end,\n                                 BOOL *fake_reserved )\n{"))
check("the query hook runs only for a range the view tree calls free",
      "if (!view && !fake_reserved) ios_query_clip_free( base, &alloc_base, &alloc_end, &fake_reserved );" in src)
check("the unmap hook runs only for an image view", "if (view->protect & SEC_IMAGE) ios_image_lowalias_retire( (unsigned long long)(uintptr_t)view->base );" in src)
check("the switches are read once each", src.count('getenv( "MADEIRA_IMAGE_LOW_ALIAS" )') == 1 and src.count('getenv( "MADEIRA_QUERY_CLIP" )') == 1)
text = (R / "recommended/recommendations.json").read_text() + (R / "build/tools/autotune_rules.py").read_text()
check("no recommended list and no auto-tune rule sets either", "MADEIRA_IMAGE_LOW_ALIAS" not in text and "MADEIRA_QUERY_CLIP" not in text)

print("PASS: query clip and image low alias" if ok else "FAIL: query clip and image low alias")
sys.exit(0 if ok else 1)
