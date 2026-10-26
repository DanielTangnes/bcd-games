#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""What BCD's system tests (tests/systests, the Start menu's "BCD Tests") are told about the device and the engine.

A Windows program cannot ask iOS how much memory the app may use, or how full the JIT pool is. Two files in the prefix carry it:
C:\\ProgramData\\BCD\\host-info.txt, written once by the app when the plain Windows desktop session starts (app/Madeira/BCDHostStatus.c),
and host-live.txt, rewritten by the engine's pool warmer thread (build/ntdll-unix/ios_host_status.h, called from virtual_ios.c).
Both are off for every other session. Checks:
  1. BCDHostStatus.c builds on the Mac and: decides who gets the status (the plain desktop only: never a game in a desktop, never
     a BCD Dock session, never with env.MADEIRA_HOST_STATUS = 0); writes host-info.txt with the keys the tests read, on one line each
     (a build string with a newline in it cannot start a second key); makes the folder, replaces the file as a whole, removes the
     last session's host-live.txt, sets MADEIRA_HOST_STATUS; and writes nothing and sets nothing when the prefix is not there.
  2. ios_host_status.h: the record's text, the whole-file replacement (a temporary file, then rename), a buffer that is too small,
     the off switch (unset, empty, "0", too long), and the round trip: what it writes is what tests/systests/core.h reads.
  3. The keys: every key the tests read is written by the app or the engine, and nothing the tests need is missing.
  4. The hooks. virtual_ios.c includes the header once, before the pool warmer, and calls the tick in the warmer's quarter-second
     branch and at the start of its full cycle; the tick returns before it touches anything when the switch is off; every static
     of virtual_ios.c the header uses is declared before the include; with the iOS SDK and the Wine tree (~/madeira-bcd) virtual_ios.c
     is compiled with its real flags (syntax only). WineProcessBridge.m calls the app side once, behind the rule, after the Start menu.
  5. The Xcode project builds the new C file; the licence headers.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
NT = R / "build/ntdll-unix"
SYS = R / "tests/systests"
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("\n     " + str(detail)[-3000:]) if detail and not cond else ""))
    ok = ok and bool(cond)


def note(text):
    print("note " + text)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def kv(text):
    d = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


DRIVER = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "BCDHostStatus.h"
#include "ios_host_status.h"
#include "core.h"

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "";
    if (!strcmp(cmd, "wanted")) {                  /* wanted <desktop> <dock> <exe> <off>; "-" is unset */
        printf("%d\n", bcd_host_status_wanted(strcmp(argv[2], "-") ? argv[2] : NULL, strcmp(argv[3], "-") ? argv[3] : NULL,
                                              strcmp(argv[4], "-") ? argv[4] : NULL, strcmp(argv[5], "-") ? argv[5] : NULL));
        return 0;
    }
    if (!strcmp(cmd, "info")) {                    /* info <build> <version> <pool> <swap> [cap] */
        bcd_host_facts f = { strcmp(argv[2], "-") ? argv[2] : NULL, strcmp(argv[3], "-") ? argv[3] : NULL,
                             strtoull(argv[4], NULL, 10), strtoull(argv[5], NULL, 10) };
        char buf[2048];
        size_t cap = argc > 6 ? (size_t)atoi(argv[6]) : sizeof buf, n = bcd_host_info_text(&f, buf, cap);
        printf("%zu\n", n);
        if (n) fwrite(buf, 1, n, stdout);
        return 0;
    }
    if (!strcmp(cmd, "prepare")) {                 /* prepare <prefix> <build> */
        bcd_host_facts f = { argv[3], "0.1.602", 1152, 0 };
        int r = bcd_host_status_prepare(argv[2], &f);
        const char *e = getenv("MADEIRA_HOST_STATUS");
        printf("%d %s\n", r, e ? e : "(unset)");
        return 0;
    }
    if (!strcmp(cmd, "overlap")) {                 /* overlap lo hi off end */
        printf("%zu\n", ios_host_status_overlap(strtoul(argv[2], NULL, 0), strtoul(argv[3], NULL, 0), strtoul(argv[4], NULL, 0), strtoul(argv[5], NULL, 0)));
        return 0;
    }
    if (!strcmp(cmd, "dir")) {                     /* the off switch of the engine's side */
        const char *d = ios_host_status_dir();
        printf("%s\n", d ? d : "(off)");
        return 0;
    }
    if (!strcmp(cmd, "write")) {                   /* write <dir> <seq> <pool 0|1> */
        ios_host_status_rec r;
        char text[768];
        size_t n;
        memset(&r, 0, sizeof r);
        r.seq = strtoull(argv[3], NULL, 10);
        r.footprint_mb = 2901; r.compressed_mb = 12; r.available_mb = 5291; r.swap_used_mb = 77;
        if (atoi(argv[4])) {
            r.have_pool = 1;
            r.pool_total_kb = 917504; r.pool_head_kb = 410000; r.pool_tail_kb = 92160; r.pool_hole_kb = 53248;
            r.pool_free_kb = 12288; r.pool_virgin_kb = 349000; r.poolc_total_kb = 418816; r.poolc_used_kb = 88000;
        }
        char tiny[40];
        n = ios_host_status_format(&r, text, sizeof text);
        printf("format=%zu small=%zu\n", n, ios_host_status_format(&r, tiny, sizeof tiny));
        printf("write=%d\n", n ? ios_host_status_write(argv[2], text, n) : -1);
        return 0;
    }
    if (!strcmp(cmd, "read")) {                    /* read <dir>: what core.h makes of host-info.txt and host-live.txt */
        char path[1100], text[4096];
        FILE *f;
        host_status h;
        size_t n;
        host_status_clear(&h);
        snprintf(path, sizeof path, "%s/host-info.txt", argv[2]);
        if ((f = fopen(path, "rb"))) { n = fread(text, 1, sizeof text - 1, f); text[n] = 0; fclose(f); host_parse_info(text, &h); }
        snprintf(path, sizeof path, "%s/host-live.txt", argv[2]);
        if ((f = fopen(path, "rb"))) { n = fread(text, 1, sizeof text - 1, f); text[n] = 0; fclose(f); host_parse_live(text, &h); }
        printf("have_info=%d have_live=%d have_pool=%d seq=%llu footprint=%llu available=%llu swap_used=%llu pool_total=%llu head=%llu tail=%llu hole=%llu "
               "free=%llu virgin=%llu c_total=%llu c_used=%llu build=%s version=%s pool_cfg=%llu\n", h.have_info, h.have_live, h.have_pool,
               h.seq, h.footprint_mb, h.available_mb, h.swap_used_mb, h.pool_total_kb, h.pool_head_kb, h.pool_tail_kb, h.pool_hole_kb,
               h.pool_free_kb, h.pool_virgin_kb, h.poolc_total_kb, h.poolc_used_kb, h.build, h.version, h.pool_cfg_mb);
        return 0;
    }
    return 2;
}
'''


# A stand-in for the part of virtual_ios.c the header reads (the same names and types), so that the gathering code the engine runs is
# the code under test: the header is included with IOS_HOST_STATUS_IN_VIRTUAL, as virtual_ios.c does.
MOCK_C = r'''
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <mach/mach.h>

static size_t jit_pool_offset;
static volatile size_t ios_jit_tail_reserved;
size_t ios_jit_pool_size_global;
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
#define IOS_POOL_FREE_MAX 256
struct ios_pool_free { size_t off; size_t size; long freed_at; int advised; };
static struct ios_pool_free ios_pool_freelist[IOS_POOL_FREE_MAX];
static int ios_pool_free_count;
static size_t ios_jit_hole_off, ios_jit_hole_end, ios_jit_hole2_off, ios_jit_hole2_end;
static size_t ios_jit_hole_off_eff, ios_jit_hole_end_eff;
size_t ios_jit_low_size_global;
static volatile size_t ios_jit_low_reserved;
static size_t g_avail;
size_t os_proc_available_memory(void) { return g_avail; }

#define IOS_HOST_STATUS_IN_VIRTUAL
#include "ios_host_status.h"

#define MB (1024ul * 1024ul)

int main(int argc, char **argv)
{
    int scenario = atoi(argv[1]), i;
    (void)argc;
    g_avail = 5000 * MB;
    ios_swap_bytes = 77 * MB;
    /* the real log of 2026-10-25 (iPhone18,2): a 896 MB span with a 47 MB and a 5 MB hole, region C of 409 MB */
    ios_jit_pool_size_global = 896 * MB;
    ios_jit_hole_off = 0x11d00000; ios_jit_hole_end = 0x14c00000;
    ios_jit_hole2_off = 0x258b8000; ios_jit_hole2_end = 0x25e18000;
    ios_jit_hole_off_eff = ios_jit_hole_off; ios_jit_hole_end_eff = ios_jit_hole_end;
    ios_jit_low_size_global = 409 * MB;
    ios_jit_low_reserved = 88 * MB;
    jit_pool_offset = 512 * MB;                 /* past the first hole, short of the second */
    ios_jit_tail_reserved = 96 * MB;
    ios_pool_free_count = 3;
    ios_pool_freelist[0].size = 8 * MB; ios_pool_freelist[1].size = 4 * MB; ios_pool_freelist[2].size = 2 * MB;
    if (scenario == 1) { jit_pool_offset = 100 * MB; }                                  /* the head has not reached the first hole */
    if (scenario == 2) { jit_pool_offset = 700 * MB; ios_jit_tail_reserved = 400 * MB; } /* head past both holes; the tail jumped the second hole */
    if (scenario == 3) { ios_jit_pool_size_global = 0; }                                /* no pool */
    if (scenario == 4) { g_avail = 0x7ffffddb00000ul; }                                 /* iOS's "no limit" sentinel */
    if (scenario == 5) { jit_pool_offset = 5000 * MB; ios_jit_tail_reserved = 5000 * MB; }  /* nonsense cursors must not wrap */
    if (scenario == 6) {                                                                 /* the pool lock is busy: the last free-list figure stays */
        ios_host_status_tick(0);
        pthread_mutex_lock(&ios_pool_lock);
        ios_pool_free_count = 1; ios_pool_freelist[0].size = 1 * MB;
        ios_host_status_tick(0);
        pthread_mutex_unlock(&ios_pool_lock);
        ios_host_status_tick(1);                                                         /* the quarter-second tick keeps the pool figures */
        ios_host_status_tick(1);
        return 0;
    }
    for (i = 0; i < 3; i++) ios_host_status_tick(0);
    ios_host_status_tick(1);
    return 0;
}
'''

# ---------------------------------------------------------------- 1 and 2: the plain parts, built on the Mac
tmp = Path(tempfile.mkdtemp(prefix="bcd-hoststatus-"))
try:
    (tmp / "driver.c").write_text(DRIVER)
    flags = ["-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-I", str(APP), "-I", str(NT), "-I", str(SYS)]
    san = []
    probe = sh(["clang", "-fsanitize=address,undefined", "-x", "c", "-", "-o", str(tmp / "probe")], input="int main(void){return 0;}")
    if probe.returncode == 0 and sh([str(tmp / "probe")]).returncode == 0:
        san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
    else:
        note("clang has no working sanitizers here; the driver runs without them")
    build = sh(["clang", *flags, *san, "-O1", "-g", str(tmp / "driver.c"), str(APP / "BCDHostStatus.c"), "-o", str(tmp / "driver")])
    check("BCDHostStatus.c, ios_host_status.h and core.h build with -Wall -Wextra -Werror" + (" and ASan/UBSan" if san else ""),
          build.returncode == 0, build.stderr)

    if build.returncode == 0:
        def run(*a, env=None):
            e = dict(os.environ)
            e.pop("MADEIRA_HOST_STATUS", None)
            e.update(env or {})
            return sh([str(tmp / "driver"), *map(str, a)], env=e)

        # who gets it
        for args, want, why in ((("1", "-", "explorer.exe", "-"), "1", "the plain Windows desktop"),
                                (("1", "-", "C:\\windows\\system32\\Explorer.EXE", "-"), "1", "a full path and another case"),
                                (("1", "0", "explorer.exe", "-"), "1", "MADEIRA_DOCK_SESSION=0 is not a Dock session"),
                                (("1", "-", "explorer.exe", "1"), "1", "any value of the switch but 0 keeps it on"),
                                (("1", "-", "RDR2.exe", "-"), "0", "a game in a Wine desktop does not"),
                                (("1", "-", "C:\\Games\\game.exe", "-"), "0", "a program in a Wine desktop does not"),
                                (("1", "-", "myexplorer.exe", "-"), "0", "only explorer.exe itself"),
                                (("1", "1", "explorer.exe", "-"), "0", "a BCD Dock session does not"),
                                (("1", "-", "explorer.exe", "0"), "0", "env.MADEIRA_HOST_STATUS = 0 leaves it out"),
                                (("-", "-", "explorer.exe", "-"), "0", "no desktop"),
                                (("0", "-", "explorer.exe", "-"), "0", "MADEIRA_DESKTOP=0"),
                                (("1", "-", "-", "-"), "0", "no program named")):
            check("wanted: %s" % why, run("wanted", *args).stdout.strip() == want, args)

        # host-info.txt
        out = run("info", "602", "0.1.602", "1152", "12228").stdout
        n_, text = out.split("\n", 1)
        d = kv(text)
        check("host-info.txt: format 1 and the keys the tests read", d.get("format") == "1" and {"build", "version", "model", "os", "ram_mb", "cores", "limit_mb",
                                                                                                "address_map_gb", "pool_cfg_mb", "swap_mb"} <= set(d), d)
        check("... the build, the version, the pool and the swap the app passes in", d.get("build") == "602" and d.get("version") == "0.1.602"
              and d.get("pool_cfg_mb") == "1152" and d.get("swap_mb") == "12228", d)
        check("... the device's RAM and cores are numbers", d.get("ram_mb", "x").isdigit() and int(d["ram_mb"]) > 0 and d.get("cores", "x").isdigit(), d)
        check("... the length it returns is the length of the text", int(n_) == len(text.encode()), (n_, len(text)))
        out = run("info", "6\nlimit_mb=999\nformat=2", "0.1\r\n", "0", "0").stdout
        d = kv(out.split("\n", 1)[1])
        check("a build string with a newline cannot start a second key", d.get("limit_mb") != "999" and d.get("format") == "1" and "\r" not in out, d)
        out = run("info", "-", "-", "0", "0").stdout
        check("no build and no version are empty values, not a crash", kv(out.split("\n", 1)[1]).get("build") == "", out)
        check("a buffer that is too small gives nothing instead of half a file", run("info", "602", "x", "0", "0", 40).stdout.strip() == "0")

        # the prefix
        prefix = tmp / "prefix"
        (prefix / "drive_c").mkdir(parents=True)
        r = run("prepare", prefix, "602").stdout.split()
        folder = prefix / "drive_c/ProgramData/BCD"
        check("prepare makes drive_c/ProgramData/BCD, writes host-info.txt and sets MADEIRA_HOST_STATUS to the folder",
              r[:1] == ["1"] and r[1:] == [str(folder)] and (folder / "host-info.txt").is_file(), r)
        check("... no temporary file is left", not list(folder.glob("*.tmp")))
        (folder / "host-live.txt").write_text("seq=99\n")
        r = run("prepare", prefix, "603").stdout.split()
        check("a second prepare replaces host-info.txt as a whole and removes the last session's host-live.txt",
              r[:1] == ["1"] and kv((folder / "host-info.txt").read_text()).get("build") == "603" and not (folder / "host-live.txt").exists())
        r = run("prepare", tmp / "nowhere", "602").stdout.split()
        check("a prefix that is not there gets nothing: 0, no folder, and the variable stays unset", r == ["0", "(unset)"] and not (tmp / "nowhere").exists(), r)
        bare = tmp / "bare"
        bare.mkdir()
        r = run("prepare", bare, "602").stdout.split()
        check("a prefix without drive_c gets nothing either", r == ["0", "(unset)"] and not (bare / "drive_c").exists(), r)

        # the engine's side
        for env, want in (({}, "(off)"), ({"MADEIRA_HOST_STATUS": ""}, "(off)"), ({"MADEIRA_HOST_STATUS": "0"}, "(off)"),
                          ({"MADEIRA_HOST_STATUS": "/x" * 600}, "(off)"), ({"MADEIRA_HOST_STATUS": "/tmp/a b"}, "/tmp/a b"),
                          ({"MADEIRA_HOST_STATUS": "00"}, "00")):
            got = run("dir", env=env).stdout.strip()
            check("the engine's directory for %r: %s" % (list(env.values())[0][:12] if env else "unset", want[:12]), got == want, got)
        live = tmp / "live"
        live.mkdir()
        w = run("write", live, 7, 1).stdout
        check("a record is formatted, a buffer that is too small gives 0, and the file is written", "small=0" in w and "write=1" in w and re.search(r"format=[1-9]\d+", w), w)
        text = (live / "host-live.txt").read_text()
        d = kv(text)
        check("host-live.txt holds the sequence number, the memory figures and the pool figures",
              d.get("seq") == "7" and d.get("footprint_mb") == "2901" and d.get("available_mb") == "5291" and d.get("pool_total_kb") == "917504"
              and d.get("pool_virgin_kb") == "349000" and d.get("poolc_used_kb") == "88000" and d.get("swap_used_mb") == "77", d)
        check("... no temporary file is left", not list(live.glob("*.tmp")))
        run("write", live, 8, 0)
        d = kv((live / "host-live.txt").read_text())
        check("a record without pool figures (the quarter-second tick before any full one) has the memory figures only", d.get("seq") == "8" and "pool_total_kb" not in d, d)
        check("the file is replaced as a whole: the new seq, no mixture", (live / "host-live.txt").read_text().count("seq=") == 1)
        w = run("write", tmp / "no-such-dir", 1, 1).stdout
        check("a directory that is not there: the write fails cleanly and leaves nothing behind", "write=0" in w and not (tmp / "no-such-dir").exists(), w)

        # the round trip: what is written is what core.h reads
        shutil.copy(folder / "host-info.txt", live / "host-info.txt")
        run("write", live, 41, 1)
        rd = kv(run("read", live).stdout.replace(" ", "\n"))
        check("core.h reads what the app and the engine write: info and live, the pool included",
              rd.get("have_info") == "1" and rd.get("have_live") == "1" and rd.get("have_pool") == "1" and rd.get("seq") == "41" and rd.get("footprint") == "2901"
              and rd.get("available") == "5291" and rd.get("pool_total") == "917504" and rd.get("head") == "410000" and rd.get("tail") == "92160"
              and rd.get("hole") == "53248" and rd.get("free") == "12288" and rd.get("virgin") == "349000" and rd.get("c_total") == "418816"
              and rd.get("c_used") == "88000" and rd.get("build") == "603" and rd.get("version") == "0.1.602" and rd.get("pool_cfg") == "1152", rd)

        # overlap of a hole with a range
        for args, want in (((0, 100, 10, 20), "10"), ((0, 15, 10, 20), "5"), ((15, 100, 10, 20), "5"), ((0, 5, 10, 20), "0"), ((25, 100, 10, 20), "0"),
                           ((0, 100, 20, 10), "0"), ((50, 40, 10, 20), "0"), ((12, 18, 10, 20), "6")):
            check("overlap%r = %s" % (args, want), run("overlap", *args).stdout.strip() == want)

        # the gathering code of the engine, with the statics of virtual_ios.c stood in for
        (tmp / "mock.c").write_text(MOCK_C)
        mock = sh(["clang", *flags, *san, "-O1", "-g", str(tmp / "mock.c"), "-o", str(tmp / "mock")])
        check("the part of ios_host_status.h that reads virtual_ios.c's statics builds against a stand-in of them (IOS_HOST_STATUS_IN_VIRTUAL)",
              mock.returncode == 0, mock.stderr)
        if mock.returncode == 0:
            MB = 1024 * 1024
            span, h1, h2 = 896 * MB, 0x14c00000 - 0x11d00000, 0x25e18000 - 0x258b8000

            def gather(scenario, status_env=True):
                d = tmp / ("gather%d" % scenario)
                d.mkdir(exist_ok=True)
                (d / "host-live.txt").unlink(missing_ok=True)
                e = dict(os.environ)
                e.pop("MADEIRA_HOST_STATUS", None)
                if status_env:
                    e["MADEIRA_HOST_STATUS"] = str(d)
                r = sh([str(tmp / "mock"), str(scenario)], env=e)
                f = d / "host-live.txt"
                return r, kv(f.read_text()) if f.exists() else None, d

            r, g, d = gather(0)
            usable = span - h1 - h2
            head_net, tail_net = 512 * MB - h1, 96 * MB
            check("scenario 0 (the 2026-10-25 log's pool): the sequence number counts the ticks, 4 here", r.returncode == 0 and g and g["seq"] == "4", (r.stderr, g))
            check("... the span, the holes and region C", g and g["pool_total_kb"] == str(span // 1024) and g["pool_hole_kb"] == str((h1 + h2) // 1024)
                  and g["poolc_total_kb"] == str(409 * 1024) and g["poolc_used_kb"] == str(88 * 1024), g)
            check("... the head without the hole it jumped, the tail, the free list, and what was never used",
                  g and g["pool_head_kb"] == str(head_net // 1024) and g["pool_tail_kb"] == str(tail_net // 1024) and g["pool_free_kb"] == str(14 * 1024)
                  and g["pool_virgin_kb"] == str((usable - head_net - tail_net) // 1024), g)
            check("... iOS's figures: available (5000 MB), the swap file's bytes (77 MB), the footprint is a number",
                  g and g["available_mb"] == "5000" and g["swap_used_mb"] == "77" and g["footprint_mb"].isdigit() and int(g["footprint_mb"]) > 0, g)
            check("... no temporary file is left", not list(d.glob("*.tmp")))
            r, g, d = gather(1)
            check("scenario 1: a head that has not reached the first hole has jumped nothing", g and g["pool_head_kb"] == str(100 * 1024), g)
            r, g, d = gather(2)
            usable = span - h1 - h2
            check("scenario 2: a tail that jumped the second hole does not count it, the head past both holes counts neither",
                  g and g["pool_head_kb"] == str((700 * MB - h1 - h2) // 1024) and g["pool_tail_kb"] == str((400 * MB - h2) // 1024)
                  and int(g["pool_virgin_kb"]) >= 0, g)
            r, g, d = gather(3)
            check("scenario 3: no pool gives the memory figures only", g and "pool_total_kb" not in g and g["seq"] == "4" and "footprint_mb" in g, g)
            r, g, d = gather(4)
            check("scenario 4: iOS's 'no limit' sentinel is not a measurement: available_mb is 0", g and g["available_mb"] == "0", g)
            r, g, d = gather(5)
            check("scenario 5: cursors past the span cannot wrap: no figure is larger than the span, the unused part is 0",
                  r.returncode == 0 and g and all(int(g[k]) <= span // 1024 for k in ("pool_head_kb", "pool_tail_kb", "pool_virgin_kb")) and g["pool_virgin_kb"] == "0", g)
            r, g, d = gather(6)
            check("scenario 6: with the pool lock busy the free-list figure of the last tick stays (14 MB), and the quarter-second tick keeps all pool figures",
                  r.returncode == 0 and g and g["pool_free_kb"] == str(14 * 1024) and g["seq"] == "4" and "pool_total_kb" in g, (r.stderr, g))
            r, g, d = gather(0, status_env=False)
            check("the switch off (MADEIRA_HOST_STATUS unset): the tick writes nothing at all", r.returncode == 0 and g is None and not list(d.iterdir()), (r.stderr, g))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# ---------------------------------------------------------------- 3: the keys
core = (SYS / "core.h").read_text()
app_c = (APP / "BCDHostStatus.c").read_text()
eng_h = (NT / "ios_host_status.h").read_text()
read_info = set(re.findall(r'kv_(?:u64|str)\(text, "(\w+)"', core[core.index("static void host_parse_info"):core.index("static void host_parse_live")]))
read_live = set(re.findall(r'kv_(?:u64|str)\(text, "(\w+)"', core[core.index("static void host_parse_live"):core.index("the RAM test's planner", core.index("static void host_parse_live"))]))
written_info = set(re.findall(r'(?:\\n|^|")(\w+)=%', app_c.replace('"\n                 "', "")))
written_info |= set(re.findall(r"\\n(\w+)=%", app_c))
written_info |= {"format", "build"}
written_live = set(re.findall(r"(?:^|\\n|\")(\w+)=%llu", eng_h)) | set(re.findall(r"\\n(\w+)=%llu", eng_h))
check("every key the tests read from host-info.txt is written by the app", read_info <= written_info, sorted(read_info - written_info))
check("every key the tests read from host-live.txt is written by the engine", read_live <= written_live, sorted(read_live - written_live))
check("the keys are the ones expected (a rename on one side is caught)",
      {"build", "version", "model", "os", "ram_mb", "limit_mb", "cores", "increased_memory", "extended_va", "address_map_gb", "pool_cfg_mb", "swap_mb"} == read_info
      and {"seq", "footprint_mb", "available_mb", "compressed_mb", "swap_used_mb", "pool_total_kb", "pool_head_kb", "pool_tail_kb", "pool_hole_kb",
           "pool_free_kb", "pool_virgin_kb", "poolc_total_kb", "poolc_used_kb"} == read_live, (sorted(read_info), sorted(read_live)))
sysc = (SYS / "systest.c").read_text()
check("the tests read the files where the app and the engine write them: C:\\ProgramData\\BCD\\host-info.txt and host-live.txt",
      'HOST_DIR  "C:\\\\ProgramData\\\\BCD"' in sysc and "drive_c/ProgramData/BCD" in app_c and '"%s/host-live.txt"' in eng_h)

# ---------------------------------------------------------------- 4: the hooks
virt = (NT / "virtual_ios.c").read_text()
inc = virt.find('#include "ios_host_status.h"')
warm = virt.find("static void *ios_pool_warmer_thread( void *arg )")
check("virtual_ios.c includes ios_host_status.h once, with IOS_HOST_STATUS_IN_VIRTUAL, before the pool warmer",
      virt.count('#include "ios_host_status.h"') == 1 and virt.count("#define IOS_HOST_STATUS_IN_VIRTUAL") == 1
      and 0 < virt.find("#define IOS_HOST_STATUS_IN_VIRTUAL") < inc < warm)
body = virt[warm:warm + 6000]
fast = body.find("ios_host_status_tick( 1 );")
full = body.find("ios_host_status_tick( 0 );")
check("the warmer calls the tick in its quarter-second branch (before the sleep and continue) and at the start of its full cycle",
      0 < fast < body.find("usleep( 250000 );") < body.find("continue;", fast) and 0 < body.find("last_full = now_ts;") < full < body.find("ios_swap_heat_tick();"))
check("both calls are the only ones", virt.count("ios_host_status_tick(") == 2 + 0 or virt.count("ios_host_status_tick( ") == 2, virt.count("ios_host_status_tick("))
tick = eng_h[eng_h.index("static void ios_host_status_tick"):]
check("the tick returns before it touches anything when the switch is off",
      0 < tick.index("if (!dir) return;") < tick.index("task_info(") and tick.index("if (!dir) return;") < tick.index("sysctlbyname"))
check("... it allocates nothing", "malloc(" not in tick and "strdup(" not in tick)
need = ["jit_pool_offset", "ios_jit_tail_reserved", "ios_jit_pool_size_global", "ios_pool_lock", "ios_pool_free_count", "IOS_POOL_FREE_MAX", "ios_pool_freelist",
        "ios_jit_hole_off", "ios_jit_hole_end", "ios_jit_hole2_off", "ios_jit_hole2_end",
        "ios_jit_low_size_global", "ios_jit_low_reserved"]
late = [n for n in need if not re.search(r"(?m)^(?:static\s+|extern\s+|#define\s+)?(?:volatile\s+)?(?:struct\s+\w+\s+|size_t\s+|pthread_mutex_t\s+|int\s+)?[^\n]*\b%s\b" % re.escape(n), virt[:inc])]
check("every static of virtual_ios.c that the header reads is declared before the include", not late, late)
check("ios_swap_bytes is declared in the header (the swap tier defines it much later in the file)",
      "static unsigned long long ios_swap_bytes;" in eng_h and re.search(r"static unsigned long long ios_swap_bytes,", virt))

build_tree = Path.home() / "madeira-bcd/wine/build-macos/include/config.h"
sdk = sh(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
if build_tree.exists() and sdk.returncode == 0:
    wine_src = Path.home() / "madeira-bcd/wine"
    wine_build = wine_src / "build-macos"
    cmd = ["xcrun", "-sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk.stdout.strip(), "-miphoneos-version-min=17.0", "-O0", "-fsyntax-only",
           "-fPIC", "-fvisibility=hidden", "-fno-stack-protector", "-fno-strict-aliasing", "-Wno-implicit-function-declaration", "-Wno-int-conversion",
           "-include", str(wine_build / "include/config.h"), "-include", str(NT / "shims/wine_ios_exit.h"), "-I", str(NT / "shims"), "-I", str(R / "build/madsync"),
           "-DHAVE_LINUX_NTSYNC_H=1", "-I", str(wine_build / "dlls/ntdll"), "-I", str(wine_src / "dlls/ntdll"), "-I", str(wine_src / "dlls/ntdll/unix"),
           "-I", str(wine_build / "include"), "-I", str(wine_src / "include"), "-D__WINESRC__", "-DLTC_NO_PROTOTYPES", "-DLTC_SOURCE", "-D_NTSYSTEM_",
           "-D_ACRTIMP=", "-DWINBASEAPI=", '-DBINDIR="/usr/local/bin"', '-DLIBDIR="/usr/local/lib"', '-DDATADIR="/usr/local/share"', '-DSYSTEMDLLPATH=""',
           "-DWINE_UNIX_LIB", "-DWINE_IOS=1", "-Dget_thread_context=ntdll_get_thread_context", "-Dset_thread_context=ntdll_set_thread_context",
           str(NT / "virtual_ios.c")]
    comp = sh(cmd, timeout=900)
    check("virtual_ios.c, hook and header included, compiles with the real flags against the iOS SDK (syntax only)",
          comp.returncode == 0 and "error:" not in comp.stderr, comp.stderr[-1500:])
else:
    note("no Wine build tree (~/madeira-bcd/wine/build-macos) or iOS SDK here: virtual_ios.c was not compiled with its real flags")

bridge = (APP / "WineProcessBridge.m").read_text()
call = bridge.find("bcd_host_status_prepare(")
check("WineProcessBridge.m includes the module and calls bcd_host_status_prepare once, behind bcd_host_status_wanted",
      '#include "BCDHostStatus.h"' in bridge and bridge.count("bcd_host_status_prepare(") == 1 and call > 0
      and "bcd_host_status_wanted(getenv(\"MADEIRA_DESKTOP\"), getenv(\"MADEIRA_DOCK_SESSION\"), getenv(\"MADEIRA_EXE\")," in bridge[call - 1500:call]
      and 'getenv("MADEIRA_HOST_STATUS")' in bridge[call - 1500:call])
check("... after the Start menu, before the VC++ overlay (so before Wine starts and reads its environment)",
      bridge.index("bcd_startmenu_install(") < call < bridge.index("Layer Microsoft's real VC++ Runtime DLLs") < bridge.index("__wine_main(argc, argv);"))
check("... and the result is logged", "[host-status]" in bridge[call:call + 900])

# ---------------------------------------------------------------- 5: the project
pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
check("the Xcode project compiles BCDHostStatus.c and lists the header", "BCDHostStatus.c in Sources" in pbx and "BCDHostStatus.h" in pbx and pbx.count("BCDHostStatus.c") >= 4)
for f in (APP / "BCDHostStatus.c", APP / "BCDHostStatus.h", NT / "ios_host_status.h", Path(__file__)):
    head = f.read_text()[:500]
    check(f.name + " has the BCD licence header", "SPDX-License-Identifier: GPL-3.0-only" in head and "LICENSE-BCD.md" in head)
wf = (R / ".github/workflows/build-ipa.yml").read_text()
check("the workflow runs this check", "tests/host/check-host-status.py" in wf)

sys.exit(0 if ok else 1)
