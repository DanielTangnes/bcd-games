#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""BCD's entries in the Start menu of Wine's desktop (BCDStartMenu.c, WineProcessBridge.m).

Wine's explorer builds the Start menu from the .lnk files under C:\\ProgramData\\Microsoft\\Windows\\Start Menu;
BCD writes an Explorer entry, its test programs (Direct3D, the system tests of round 602) and Windows' own tools there, as
shortcut files in the binary Shell Link format ([MS-SHLLINK]). An entry names a program of the 64-bit farms (system32), else of
the 32-bit set (syswow64), may carry arguments, and sits in a folder ("BCD Tests", "BCD Tools"). Checks:
  1. The bytes. BCDStartMenu.c is built on the host into a driver, and every shortcut it writes is
       - parsed by a port of Wine's loader (dlls/shell32/shelllink.c: IPersistStream::Load with
         Stream_ReadChunk, Stream_LoadLocation, Stream_LoadVolume, Stream_LoadPath, Stream_LoadString, the
         trailing zero word), which has to give the target path, the description, the working folder and
         the arguments back, and to reach the end of the file exactly;
       - parsed by the independent reader below, which walks the [MS-SHLLINK] structures by their
         offsets and sizes and checks them against the file's length (the header, the LinkInfo block, the
         VolumeID, the string data, the terminal block);
       - dumped by Wine's own winedump (`winedump dump x.lnk`, built in ~/madeira-bcd/wine/build-native) when
         the build tree has it: its local path and description must be the ones BCD wrote.
  2. What the install does in a prefix: it needs the template's public Start Menu folder, writes only the
     entries whose program the app carries, is idempotent (a second run writes nothing), brings an
     outdated BCD file up to date, and never touches a file without BCD's marker, a symlink or a folder of
     the same name; the files are the same bytes every time. A 32-bit program is started from C:\\windows\\syswow64, the 64-bit
     one wins when both farms have the name, arguments reach the link, and a BCD shortcut of an earlier build's folder is
     removed (and the folder when it is empty) while a file of a person's own there stays.
  3. The session: only a desktop session (MADEIRA_DESKTOP=1, not a BCD Dock session) gets the files, env.MADEIRA_START_MENU = 0
     leaves them out, the call sits with the session's other prefix work, and a game that is not started
     in a Wine desktop sees no change.
  4. The Xcode project builds the new C files; the licence headers; the programs the entries name are
     the ones tools/build-dx-tests.sh, tools/build-systests.sh and the D3D12 build ship, or Wine's own tools; the workflow runs
     this check. The host status the system tests read (BCDHostStatus.c) is checked in check-host-status.py.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("\n     " + str(detail)[-3000:]) if detail and not cond else ""))
    ok = ok and bool(cond)


def note(text):
    print("note " + text)


# ---------------------------------------------------------------- 1. the bytes
DRIVER_C = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "BCDStartMenu.c"          /* the module itself, so that its static helpers can be called */

/* ---- a port of Wine's shell link loader (dlls/shell32/shelllink.c), reading from memory ---- */
#pragma pack(push,1)
typedef struct { uint32_t dwSize; uint8_t MagicGuid[16]; uint32_t dwFlags; uint32_t dwFileAttr;
                 uint64_t CreationTime, AccessTime, WriteTime; uint32_t dwFileSize; uint32_t nIcon; uint32_t fStartup;
                 uint16_t wHotKey; uint16_t Reserved1; uint32_t Reserved2; uint32_t Reserved3; } LINK_HEADER;
typedef struct { uint32_t dwTotalSize, dwHeaderSize, dwFlags, dwVolTableOfs, dwLocalPathOfs, dwNetworkVolTableOfs, dwFinalPathOfs; } LOCATION_INFO;
typedef struct { uint32_t dwSize, dwType, dwVolSerial, dwVolLabelOfs; } LOCAL_VOLUME_INFO;
#pragma pack(pop)
#define SLDF_HAS_ID_LIST 1u
#define SLDF_HAS_LINK_INFO 2u
#define SLDF_HAS_NAME 4u
#define SLDF_HAS_RELPATH 8u
#define SLDF_HAS_WORKINGDIR 0x10u
#define SLDF_HAS_ARGS 0x20u
#define SLDF_HAS_ICONLOCATION 0x40u
#define PORT_UNICODE 0x80u
#define SLDF_HAS_LOGO3ID 0x100u
#define SLDF_HAS_DARWINID 0x1000u

typedef struct { const uint8_t *d; size_t n, pos; } stream;
/* IStream_Read: returns how many bytes it gave, a short read at the end of the data */
static size_t srd(stream *s, void *buf, size_t len)
{
    size_t avail = s->n - s->pos, c = len < avail ? len : avail;
    memcpy(buf, s->d + s->pos, c);
    s->pos += c;
    return c;
}

/* Stream_ReadChunk: a 32-bit size that counts itself, then size-4 bytes; the chunk keeps the size field */
static uint8_t *read_chunk(stream *s)
{
    uint32_t size;
    uint8_t *chunk;
    if (srd(s, &size, 4) != 4) return NULL;
    if (size < 4) return NULL;                         /* Wine would read (size - 4) wrapped; BCD never writes it */
    chunk = malloc(size);
    memcpy(chunk, &size, 4);
    if (srd(s, chunk + 4, size - 4) != size - 4) { free(chunk); return NULL; }
    return chunk;
}

/* Stream_LoadPath: an ANSI string of at most maxlen bytes, ASCII widened here */
static char *load_path(const char *p, uint32_t maxlen)
{
    uint32_t len = 0;
    char *out;
    while (len < maxlen && p[len]) len++;
    out = malloc(len + 1);
    memcpy(out, p, len);
    out[len] = 0;
    return out;
}

/* Stream_LoadLocation + Stream_LoadVolume */
static int load_location(stream *s, char **path, uint32_t *vol_type, char *label, size_t labelcap)
{
    uint8_t *p = read_chunk(s);
    LOCATION_INFO *loc;
    uint32_t n;
    if (!p) return 0;
    loc = (LOCATION_INFO *)p;
    if (loc->dwTotalSize < sizeof(LOCATION_INFO)) { free(p); return 0; }
    if (loc->dwVolTableOfs && loc->dwVolTableOfs + sizeof(LOCAL_VOLUME_INFO) <= loc->dwTotalSize) {
        LOCAL_VOLUME_INFO *vol = (LOCAL_VOLUME_INFO *)&p[loc->dwVolTableOfs];
        *vol_type = vol->dwType;
        if (vol->dwVolLabelOfs && vol->dwSize > vol->dwVolLabelOfs) {
            uint32_t len = vol->dwSize - vol->dwVolLabelOfs;
            const char *l = (const char *)vol + vol->dwVolLabelOfs;
            size_t i = 0;
            while (i < len && l[i] && i + 1 < labelcap) { label[i] = l[i]; i++; }
            label[i] = 0;
        }
    }
    n = loc->dwLocalPathOfs;
    if (n && n < loc->dwTotalSize) *path = load_path((char *)&p[n], loc->dwTotalSize - n);
    free(p);
    return 1;
}

/* Stream_LoadString: a 16-bit count (characters when unicode), the text, no terminator in the file */
static int load_string(stream *s, int unicode, char **out)
{
    uint16_t len;
    uint32_t bytes;
    uint8_t *temp;
    size_t i, count;
    if (srd(s, &len, 2) != 2) return 0;
    bytes = unicode ? (uint32_t)len * 2 : len;
    temp = malloc(bytes + 2);
    if (srd(s, temp, bytes) != bytes) { free(temp); return 0; }
    count = unicode ? bytes / 2 : bytes;
    *out = malloc(count + 1);
    for (i = 0; i < count; i++) {
        if (unicode) {
            uint16_t c = (uint16_t)(temp[2 * i] | (temp[2 * i + 1] << 8));
            (*out)[i] = c < 0x80 ? (char)c : '?';
        } else (*out)[i] = (char)temp[i];
    }
    (*out)[count] = 0;
    free(temp);
    return 1;
}

typedef struct { char *path, *desc, *rel, *workdir, *args, *icon; uint32_t vol_type; char label[16]; int zero_word, at_end; uint32_t flags; } loaded;

/* IPersistStream::Load, in Wine's order and with its checks; returns 1 for S_OK */
static int wine_load(const uint8_t *data, size_t len, loaded *L)
{
    stream s = { data, len, 0 };
    LINK_HEADER hdr;
    uint32_t zero = 1;
    int unicode;
    memset(L, 0, sizeof *L);
    if (sizeof(hdr) != 0x4C) return 0;
    if (srd(&s, &hdr, sizeof hdr) != sizeof hdr) return 0;
    if (hdr.dwSize != sizeof hdr) return 0;
    {
        static const uint8_t clsid[16] = { 0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46 };
        if (memcmp(hdr.MagicGuid, clsid, 16) != 0) return 0;
    }
    L->flags = hdr.dwFlags;
    if (hdr.dwFlags & SLDF_HAS_ID_LIST) return 0;          /* BCD writes none; the port does not read one */
    if ((hdr.dwFlags & SLDF_HAS_LINK_INFO) && !load_location(&s, &L->path, &L->vol_type, L->label, sizeof L->label)) return 0;
    unicode = (hdr.dwFlags & PORT_UNICODE) != 0;
    if ((hdr.dwFlags & SLDF_HAS_NAME) && !load_string(&s, unicode, &L->desc)) return 0;
    if ((hdr.dwFlags & SLDF_HAS_RELPATH) && !load_string(&s, unicode, &L->rel)) return 0;
    if ((hdr.dwFlags & SLDF_HAS_WORKINGDIR) && !load_string(&s, unicode, &L->workdir)) return 0;
    if ((hdr.dwFlags & SLDF_HAS_ARGS) && !load_string(&s, unicode, &L->args)) return 0;
    if ((hdr.dwFlags & SLDF_HAS_ICONLOCATION) && !load_string(&s, unicode, &L->icon)) return 0;
    if (hdr.dwFlags & (SLDF_HAS_LOGO3ID | SLDF_HAS_DARWINID)) return 0;
    L->zero_word = srd(&s, &zero, 4) == 4 && zero == 0;     /* Wine only warns when this is not so */
    L->at_end = s.pos == s.n;
    return 1;
}

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    uint8_t *b;
    long n;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    b = malloc((size_t)n + 1);
    if (fread(b, 1, (size_t)n, f) != (size_t)n) { fclose(f); return NULL; }
    fclose(f);
    *len = (size_t)n;
    return b;
}

static void put(const char *p, const char *what) { (void)p; (void)what; }

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "";
    (void)put;
    if (!strcmp(cmd, "install")) {                /* install <prefix> <bundle> */
        bcd_start_result r = bcd_startmenu_install(argv[2], argv[3]);
        printf("written=%d current=%d foreign=%d missing=%d failed=%d no_menu=%d retired=%d x86=%d\n",
               r.written, r.current, r.foreign, r.missing, r.failed, r.no_menu, r.retired, r.x86);
        return 0;
    }
    if (!strcmp(cmd, "entries")) {               /* folder|name|program|description|arguments|flags, both tables */
        size_t i;
        for (i = 0; i < bcd_start_all_count(); i++) {
            const bcd_start_entry *e = bcd_start_all_entry(i);
            printf("%s|%s|%s|%s|%s|%u\n", e->folder, e->name, e->program, e->description, e->arguments ? e->arguments : "", e->flags);
        }
        return 0;
    }
    if (!strcmp(cmd, "retired")) {               /* folder|name of the shortcuts an earlier build wrote */
        size_t i;
        for (i = 0; i < bcd_start_retired_count; i++) printf("%s|%s\n", bcd_start_retired[i].folder, bcd_start_retired[i].name);
        return 0;
    }
    if (!strcmp(cmd, "farm")) {                  /* farm <bundle> <program> <flags>: where the program is found */
        bcd_start_entry e = { "", "x", argv[3], "d", NULL, (unsigned)atoi(argv[4]) };
        printf("%d\n", program_farm(argv[2], &e));
        return 0;
    }
    if (!strcmp(cmd, "counts")) {                /* the four tables are what all_count/all_entry walk */
        size_t i, n = 0;
        for (i = 0; bcd_start_all_entry(i); i++) n++;
        printf("%zu %zu %zu %zu %zu %zu\n", bcd_start_entry_count, bcd_start_system_entry_count, bcd_start_extra_entry_count,
               bcd_start_more_entry_count, bcd_start_all_count(), n);
        return 0;
    }
    if (!strcmp(cmd, "load")) {                   /* load <file> */
        size_t len;
        uint8_t *b = slurp(argv[2], &len);
        loaded L;
        if (!b) { puts("unreadable"); return 1; }
        if (!wine_load(b, len, &L)) { puts("REFUSED"); return 1; }
        printf("flags=%#x\npath=%s\ndesc=%s\nworkdir=%s\nargs=%s\nvoltype=%u\nlabel=%s\nzero=%d\nend=%d\nowner=%d\n", L.flags,
               L.path ? L.path : "(none)", L.desc ? L.desc : "(none)", L.workdir ? L.workdir : "(none)",
               L.args ? L.args : "(none)", L.vol_type, L.label, L.zero_word, L.at_end, bcd_lnk_owner(b, len));
        return 0;
    }
    if (!strcmp(cmd, "build")) {                  /* build <out> <target> <desc> [args [workdir]] */
        uint8_t buf[8192];
        size_t n = bcd_lnk_build(argv[3], argc > 5 && *argv[5] ? argv[5] : NULL, argc > 6 && *argv[6] ? argv[6] : NULL,
                                 argv[4], buf, sizeof buf);
        FILE *f;
        if (!n) { puts("refused"); return 1; }
        f = fopen(argv[2], "wb"); fwrite(buf, 1, n, f); fclose(f);
        printf("%zu\n", n);
        return 0;
    }
    if (!strcmp(cmd, "owner")) {                  /* owner <file> */
        size_t len;
        uint8_t *b = slurp(argv[2], &len);
        printf("%d\n", b ? bcd_lnk_owner(b, len) : -9);
        return 0;
    }
    if (!strcmp(cmd, "small")) {                  /* a buffer that is too small is refused, never overrun */
        uint8_t buf[512], big[512];
        size_t n, need = bcd_lnk_build("C:\\windows\\system32\\explorer.exe", NULL, NULL, "x", big, sizeof big);
        int bad = need == 0;
        for (n = 0; n < 300; n++) {
            size_t got;
            memset(buf, 0xAA, sizeof buf);
            got = bcd_lnk_build("C:\\windows\\system32\\explorer.exe", NULL, NULL, "x", buf, n);
            if (n < need && got != 0) bad++;
            if (n >= need && (got != need || memcmp(buf, big, need) != 0)) bad++;
            if (n < 500 && memcmp(buf + n, "\xAA\xAA\xAA\xAA", 4) != 0) bad++;   /* nothing past `cap` */
        }
        printf("bad=%d need=%zu\n", bad, need);
        return 0;
    }
    return 2;
}
'''


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


tmp = Path(tempfile.mkdtemp(prefix="bcd-startmenu-"))
try:
    drv_c = tmp / "driver.c"
    drv_c.write_text(DRIVER_C)
    drv = tmp / "driver"
    flags = ["-std=gnu11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-I", str(APP)]
    san = []
    probe = sh(["clang", "-fsanitize=address,undefined", "-x", "c", "-", "-o", str(tmp / "probe")], input="int main(void){return 0;}")
    if probe.returncode == 0 and sh([str(tmp / "probe")]).returncode == 0:
        san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
    else:
        note("clang has no working sanitizers here; the driver runs without them")
    build = sh(["clang", *flags, *san, "-O1", "-g", str(drv_c), "-o", str(drv)])
    check("BCDStartMenu.c and the driver build with -Wall -Wextra -Werror" + (" and ASan/UBSan" if san else ""),
          build.returncode == 0, build.stderr)

    def run(*a):
        return sh([str(drv), *map(str, a)])

    def fields(out):
        d = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                d[k] = v
        return d

    # An independent reader: [MS-SHLLINK] by offsets and sizes, strict about every length.
    def spec_parse(b):
        problems = []
        if len(b) < 0x4C + 4:
            return {"problems": ["shorter than a header and a terminal block"]}
        if struct.unpack_from("<I", b, 0)[0] != 0x4C:
            problems.append("HeaderSize is not 0x4C")
        if b[4:20] != bytes.fromhex("0114020000000000c000000000000046"):
            problems.append("LinkCLSID is not 00021401-0000-0000-C000-000000000046")
        flags_ = struct.unpack_from("<I", b, 0x14)[0]
        info = {"flags": flags_}
        if struct.unpack_from("<I", b, 0x3C)[0] not in (1, 3, 7):
            problems.append("ShowCommand is not SW_SHOWNORMAL, SHOWMAXIMIZED or SHOWMINNOACTIVE")
        if struct.unpack_from("<H", b, 0x42)[0] != 0 or struct.unpack_from("<I", b, 0x44)[0] != 0 or struct.unpack_from("<I", b, 0x48)[0] != 0:
            problems.append("a reserved field is not zero")
        pos = 0x4C
        if flags_ & 1:
            pos += 2 + struct.unpack_from("<H", b, pos)[0]
        if flags_ & 2:
            size, hsize, lflags, vofs, lofs, nofs, sofs = struct.unpack_from("<IIIIIII", b, pos)
            if pos + size > len(b):
                problems.append("LinkInfoSize runs past the file")
            if hsize != 0x1C:
                problems.append("LinkInfoHeaderSize is not 0x1C (no optional Unicode offsets)")
            if lflags != 1:
                problems.append("LinkInfoFlags is not VolumeIDAndLocalBasePath")
            if vofs != 0x1C:
                problems.append("VolumeIDOffset is not right behind the header")
            vsize, dtype, serial, loff = struct.unpack_from("<IIII", b, pos + vofs)
            if vsize <= 0x10 or loff != 0x10 or vofs + vsize != lofs:
                problems.append("VolumeID size or label offset is wrong")
            if dtype not in (0, 1, 2, 3, 4, 5, 6):
                problems.append("DriveType is not a drive type")
            if nofs != 0:
                problems.append("CommonNetworkRelativeLinkOffset set without the flag")
            end = b.index(b"\0", pos + lofs)
            info["base"] = b[pos + lofs:end].decode("ascii")
            if sofs != lofs + len(info["base"]) + 1:
                problems.append("CommonPathSuffixOffset is not right behind the base path")
            if b[pos + sofs] != 0 or sofs + 1 != size:
                problems.append("the common path suffix is not one empty string ending the block")
            pos += size
        for bit, key in ((4, "name"), (8, "rel"), (0x10, "dir"), (0x20, "args"), (0x40, "icon")):
            if flags_ & bit:
                n = struct.unpack_from("<H", b, pos)[0]
                pos += 2
                if flags_ & 0x80:
                    info[key] = b[pos:pos + 2 * n].decode("utf-16-le")
                    pos += 2 * n
                else:
                    info[key] = b[pos:pos + n].decode("ascii")
                    pos += n
        if len(b) != pos + 4 or struct.unpack_from("<I", b, pos)[0] >= 4:
            problems.append("the file does not end with a terminal block of four bytes")
        info["problems"] = problems
        return info

    if build.returncode == 0:
        work = tmp / "bundle-test"
        prefix = work / "prefix"
        bundle = work / "app"
        menu = prefix / "drive_c/ProgramData/Microsoft/Windows/Start Menu"
        (menu / "Programs").mkdir(parents=True)
        (bundle / "arm64ec-windows").mkdir(parents=True)
        (bundle / "aarch64-windows").mkdir(parents=True)

        (bundle / "i386-windows").mkdir(parents=True)

        # every entry of both tables: folder|name|program|description|arguments|flags
        ents = [l.split("|") for l in run("entries").stdout.splitlines()]
        counts = run("counts").stdout.split()
        check("the four tables are what the walk over all entries covers", len(counts) == 6 and
              int(counts[0]) + int(counts[1]) + int(counts[2]) + int(counts[3]) == int(counts[4]) == int(counts[5]) == len(ents)
              and int(counts[1]) > 0 and int(counts[2]) > 0 and int(counts[3]) > 0,
              counts)
        names = [e[1] for e in ents]
        check("Explorer is the one entry at the top of the menu, every other entry is in a folder below Programs",
              [e[1] for e in ents if e[0] == ""] == ["Explorer"] and all(e[0].startswith("Programs/") for e in ents if e[1] != "Explorer"), ents)
        check("no two entries are the same file", len({(e[0], e[1]) for e in ents}) == len(ents), names)
        check("every name is plain: no path separator, no ':' that a Windows file name cannot hold",
              all(not set('/\\:*?"<>|') & set(e[1]) for e in ents), names)
        programs = {e[1]: e[2] for e in ents}
        check("the entries start explorer.exe and the x64 test programs of the four Direct3D versions",
              programs.get("Explorer") == "explorer.exe" and {"d3d9-cube-x64.exe", "d3d10-cube-x64.exe", "d3d11-cube-x64.exe", "d3d12-cube-x64.exe"}
              <= set(programs.values()), programs)
        dx_entries = [e for e in ents if e[2] in ("d3d9-cube-x64.exe", "d3d10-cube-x64.exe", "d3d11-cube-x64.exe", "d3d12-cube-x64.exe")]
        check("the DirectX tests are in 'BCD Tests', which is where the system tests are", {e[0] for e in dx_entries} == {"Programs/BCD Tests"}, dx_entries)

        # the system tests (round 602): one program, told what to do by its first argument
        sysent = {e[1]: e for e in ents if e[2].startswith("bcd-systest-")}
        want_sys = {"Run all tests": "all", "System info": "sysinfo", "CPU test": "cpu", "RAM test 2 GB": "ram 2", "RAM test 4 GB": "ram 4",
                    "RAM test 6 GB": "ram 6", "RAM test 8 GB": "ram 8", "RAM test 12 GB": "ram 12", "RAM test (32-bit)": "ram32",
                    "JIT pool test": "jit", "VC++ and .NET check": "vcrt", "Disk speed test": "disk", "Network test": "net"}
        check("the system tests: one entry for each test, each with its argument, all in 'BCD Tests'",
              {n: e[4] for n, e in sysent.items()} == want_sys and {e[0] for e in sysent.values()} == {"Programs/BCD Tests"}, sysent)
        check("five RAM tests (2, 4, 6, 8 and 12 GB) are one program with an argument",
              sorted(e[4] for n, e in sysent.items() if n.startswith("RAM test ") and "GB" in n) == ["ram 12", "ram 2", "ram 4", "ram 6", "ram 8"]
              and {e[2] for n, e in sysent.items() if n.startswith("RAM test ") and "GB" in n} == {"bcd-systest-x64.exe"})
        check("the 32-bit window test is the 32-bit build of the program", sysent["RAM test (32-bit)"][2] == "bcd-systest-x86.exe", sysent)
        tools = {e[1]: e for e in ents if e[0] == "Programs/BCD Tools"}
        check("the Tools folder: Task Manager, Command Prompt, Notepad, Registry Editor and Game Controllers (control.exe joy.cpl)",
              {n: (e[2], e[4]) for n, e in tools.items() if n in ("Task Manager", "Command Prompt", "Notepad", "Registry Editor", "Game Controllers")}
              == {"Task Manager": ("taskmgr.exe", ""), "Command Prompt": ("cmd.exe", ""),
                  "Notepad": ("notepad.exe", ""), "Registry Editor": ("regedit.exe", ""),
                  "Game Controllers": ("control.exe", "joy.cpl")}, tools)
        # round 603: winecfg, the Control Panel and "Uninstall a program" (appwiz.cpl) beside them, the runtimes folder and 7-Zip
        check("the Tools folder also has Wine Configuration (winecfg.exe), the Control Panel (control.exe) and Uninstall a program (control.exe appwiz.cpl)",
              {n: (e[2], e[4]) for n, e in tools.items() if n in ("Wine Configuration", "Control Panel", "Uninstall a program")}
              == {"Wine Configuration": ("winecfg.exe", ""), "Control Panel": ("control.exe", ""), "Uninstall a program": ("control.exe", "appwiz.cpl")}, tools)
        runtimes = {e[1]: e for e in ents if e[0] == "Programs/BCD Runtimes"}
        check("the Runtimes folder: one program, a status entry and one entry for each of XNA, PhysX, OpenAL and DirectX June 2010 with its argument",
              {n: (e[2], e[4]) for n, e in runtimes.items()} == {"Installed runtimes": ("bcd-runtimes-x64.exe", "status"),
                  "XNA Framework 4.0": ("bcd-runtimes-x64.exe", "xna"), "PhysX (legacy)": ("bcd-runtimes-x64.exe", "physx"),
                  "OpenAL": ("bcd-runtimes-x64.exe", "openal"), "DirectX June 2010": ("bcd-runtimes-x64.exe", "dx2010")}, runtimes)
        zip7 = {e[1]: e for e in ents if e[0] == "Programs/7-Zip"}
        check("7-Zip has its own folder with the File Manager (7zFM.exe), no argument", {n: (e[2], e[4]) for n, e in zip7.items()} == {"7-Zip File Manager": ("7zFM.exe", "")}, zip7)
        check("no entry is forced to the 32-bit set by a flag (a 32-bit program is found by where the app carries it), except Internet Explorer: "
              "the 32-bit one, written only with Wine Gecko (flags 1 | 2)",
              all(e[5] == "0" for e in ents if e[1] != "Internet Explorer") and [e[5] for e in ents if e[1] == "Internet Explorer"] == ["3"],
              [e for e in ents if e[5] != "0"])
        # round 604: WordPad, Winefile, the Display and Internet options panels, Internet Explorer and WineMine
        more = {e[1]: e for e in ents if e[1] in ("WordPad", "File Manager (Winefile)", "Display settings", "Internet options", "Internet Explorer", "Minesweeper (WineMine)")}
        check("round 604's programs: WordPad, Winefile, the Display and Internet options panels (control.exe with desk.cpl / inetcpl.cpl), Internet Explorer and WineMine",
              {n_: (e[0], e[2], e[4]) for n_, e in more.items()} == {
                  "WordPad": ("Programs/BCD Tools", "wordpad.exe", ""), "File Manager (Winefile)": ("Programs/BCD Tools", "winefile.exe", ""),
                  "Display settings": ("Programs/BCD Tools", "control.exe", "desk.cpl"), "Internet options": ("Programs/BCD Tools", "control.exe", "inetcpl.cpl"),
                  "Internet Explorer": ("Programs/BCD Tools", "iexplore.exe", ""), "Minesweeper (WineMine)": ("Programs/BCD Tests", "winemine.exe", "")}, more)
        check("no entry names a control panel Wine does not have (intl.cpl, main.cpl, mmsys.cpl are not in Wine's tree)",
              not [e for e in ents if e[4] in ("intl.cpl", "main.cpl", "mmsys.cpl")])

        # which farm carries what: the 32-bit tests and control.exe in i386-windows, the Windows programs in aarch64-windows, the rest in arm64ec-windows
        def farm_of(prog):
            if prog.endswith("-x86.exe") or prog in ("control.exe", "joy.cpl", "wordpad.exe", "winefile.exe", "iexplore.exe"):
                return "i386-windows"
            if prog in ("explorer.exe", "cmd.exe", "notepad.exe", "regedit.exe", "taskmgr.exe", "winecfg.exe", "winemine.exe"):
                return "aarch64-windows"
            return "arm64ec-windows"

        def stock(farms):
            for p in {e[2] for e in ents}:
                if farm_of(p) in farms:
                    (bundle / farm_of(p)).mkdir(exist_ok=True)
                    (bundle / farm_of(p) / p).write_bytes(b"MZ")
            if "i386-windows" in farms:
                (bundle / "i386-windows" / "ntdll.dll").write_bytes(b"MZ")      # what makes the folder a 32-bit set

        stock({"arm64ec-windows", "aarch64-windows", "i386-windows"})
        (prefix / "drive_c/windows/system32/gecko").mkdir(parents=True)          # Wine Gecko is in this prefix: Internet Explorer gets its entry
        n_x86 = sum(1 for e in ents if farm_of(e[2]) == "i386-windows")
        check("some entries are 32-bit programs (the 32-bit RAM test, Game Controllers)", n_x86 >= 2, n_x86)

        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        n = len(ents)
        check("the first install writes every entry and says how many are 32-bit",
              r == {"written": str(n), "current": "0", "foreign": "0", "missing": "0", "failed": "0", "no_menu": "0", "retired": "0", "x86": str(n_x86)}, r)
        files = {(e[0], e[1]): menu / e[0] / (e[1] + ".lnk") for e in ents}
        check("the files are where Wine's menu looks", all(f.is_file() for f in files.values()), [str(f) for f in files.values()][:5])
        folders = sorted({e[0] for e in ents if e[0]})
        check("nothing but the links and the BCD folders was added",
              sorted(str(p.relative_to(menu)) for p in menu.rglob("*") if p.is_file()) == sorted(str(f.relative_to(menu)) for f in files.values())
              and sorted(str(p.relative_to(menu)) for p in menu.rglob("*") if p.is_dir()) ==
              sorted({"Programs"} | {"/".join(f.split("/")[:i + 1]) for f in folders for i in range(len(f.split("/")))}),
              sorted(str(p.relative_to(menu)) for p in menu.rglob("*")))

        for e in ents:
            f = files[(e[0], e[1])]
            name = e[1]
            wine = fields(run("load", f).stdout)
            spec = spec_parse(f.read_bytes())
            sysdir = "syswow64" if farm_of(e[2]) == "i386-windows" else "system32"
            want_target = "C:\\windows\\" + sysdir + "\\" + e[2]
            check(name + ": Wine's loader gives the target (" + sysdir + "), the description, the arguments, no folder, and the whole file",
                  wine.get("path") == want_target and wine.get("desc", "").startswith("[BCD] ") and wine.get("workdir") == "(none)"
                  and wine.get("args") == (e[4] or "(none)") and wine.get("zero") == "1" and wine.get("end") == "1" and wine.get("owner") == "1"
                  and wine.get("voltype") == "3", wine)
            check(name + ": [MS-SHLLINK] by its offsets and sizes", not spec["problems"] and spec.get("base") == want_target
                  and spec.get("name", "").startswith("[BCD] ") and spec.get("args", "") == e[4], spec)
            check(name + ": a name string Wine's menu can show (the file name; the description is only a tooltip)",
                  f.stem == name and "/" not in name and "\\" not in name)
        files_by_name = {e[1]: files[(e[0], e[1])] for e in ents}

        # the same bytes every time, and with arguments and a working folder
        a, b = tmp / "a.lnk", tmp / "b.lnk"
        run("build", a, "C:\\windows\\system32\\x.exe", "With arguments", "-one \"two\"", "C:\\windows")
        run("build", b, "C:\\windows\\system32\\x.exe", "With arguments", "-one \"two\"", "C:\\windows")
        check("a link is the same bytes every time", a.read_bytes() == b.read_bytes())
        wine = fields(run("load", a).stdout)
        spec = spec_parse(a.read_bytes())
        check("arguments and a working folder come back through Wine's loader",
              wine.get("args") == '-one "two"' and wine.get("workdir") == "C:\\windows" and wine.get("zero") == "1" and wine.get("end") == "1", wine)
        check("... and through the independent reader", not spec["problems"] and spec.get("args") == '-one "two"' and spec.get("dir") == "C:\\windows", spec)

        # winedump, Wine's own dumper, when this checkout is next to a build tree
        for cand in (os.environ.get("WINEDUMP"), str(R / "wine/build-native/tools/winedump/winedump"),
                     str(Path.home() / "madeira-bcd/wine/build-native/tools/winedump/winedump")):
            if cand and Path(cand).exists():
                dumped = sh([cand, "dump", str(files_by_name["Explorer"])])
                text = dumped.stdout
                check("winedump parses the Explorer link: HAS_LINK_INFO HAS_NAME UNICODE, local path, description",
                      dumped.returncode == 0 and "HAS_LINK_INFO HAS_NAME UNICODE" in text
                      and 'LocalPath ofs = 0000002d ("C:\\windows\\system32\\explorer.exe")' in text
                      and "Description : [BCD] Opens Wine's file manager" in text and "Done dumping" in text, text)
                dumped = sh([cand, "dump", str(a)])
                check("winedump parses a link with arguments and a working folder",
                      dumped.returncode == 0 and "HAS_WORKINGDIR" in dumped.stdout and "HAS_ARGS" in dumped.stdout
                      and "-one" in dumped.stdout and "C:\\windows" in dumped.stdout, dumped.stdout)
                dumped = sh([cand, "dump", str(files_by_name["Game Controllers"])])
                check("winedump parses the Game Controllers link: syswow64 target and the joy.cpl argument",
                      dumped.returncode == 0 and "HAS_ARGS" in dumped.stdout and "joy.cpl" in dumped.stdout
                      and "C:\\windows\\syswow64\\control.exe" in dumped.stdout, dumped.stdout)
                break
        else:
            note("winedump is not built here (wine/build-native/tools/winedump): Wine's dumper was not run")

        # idempotent: a second run writes nothing
        before = {n_: f.read_bytes() for n_, f in files_by_name.items()}
        stamp = {n_: f.stat().st_mtime_ns for n_, f in files_by_name.items()}
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("a second install writes nothing", r.get("written") == "0" and r.get("current") == str(n) and r.get("failed") == "0"
              and r.get("x86") == str(n_x86), r)
        check("... and the files are the same bytes and were not rewritten",
              all(f.read_bytes() == before[k] and f.stat().st_mtime_ns == stamp[k] for k, f in files_by_name.items()))
        check("no temporary file is left", not list(menu.rglob("*.bcdtmp")))

        # an outdated BCD file is brought up to date
        old_name = "DirectX 9 test" if "DirectX 9 test" in files_by_name else "RAM test 4 GB"
        old = files_by_name[old_name]
        run("build", old, "C:\\windows\\system32\\d3d9-old.exe", "Older text")
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("a BCD file that is outdated is written again, the rest stay", r.get("written") == "1" and r.get("current") == str(n - 1), r)
        check("... with the bytes of the current entry", old.read_bytes() == before[old_name])
        # an outdated argument is outdated too
        ram = files_by_name["RAM test 4 GB"]
        run("build", ram, "C:\\windows\\system32\\bcd-systest-x64.exe", "x", "ram 2")
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("a link with the right program and another argument is brought up to date", r.get("written") == "1" and ram.read_bytes() == before["RAM test 4 GB"], r)

        # never a file that is not BCD's
        victims = [k for k in files_by_name if k.startswith("RAM test ") and "GB" in k][:3]
        mine, other, sym = (files_by_name[v] for v in victims)
        own = b"MZ-not-a-link, written by a person"
        mine.write_bytes(own)
        # a real-looking link of the person's own: no marker
        run("build", other, "C:\\Games\\mine.exe", "x")
        data = bytearray(other.read_bytes())
        data = bytes(data).replace("[BCD] ".encode("utf-16-le"), "mine: ".encode("utf-16-le"))
        other.write_bytes(data)
        link_target = tmp / "elsewhere.lnk"
        link_target.write_bytes(b"kept")
        sym.unlink()
        sym.symlink_to(link_target)
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("files that are not BCD's (not a link, a person's own link, a symbolic link) are counted and left alone",
              r.get("foreign") == "3" and r.get("written") == "0" and r.get("failed") == "0", r)
        check("... byte for byte", mine.read_bytes() == own and other.read_bytes() == data and sym.is_symlink() and link_target.read_bytes() == b"kept")
        for f in (mine, other):
            f.unlink()
        sym.unlink()
        sym.mkdir()                                            # a folder where the file should be
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("a folder of the entry's name is left alone and not counted as written", r.get("foreign") == "1" and r.get("written") == "2", r)
        sym.rmdir()
        run("install", prefix, bundle)                         # back to a full menu

        # an entry whose program the app does not carry gets none; a bundle without the 32-bit set loses the 32-bit entries only
        shutil.rmtree(menu)
        (menu / "Programs").mkdir(parents=True)
        shutil.rmtree(bundle / "i386-windows")
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("a bundle without the 32-bit set: its entries are skipped, the others are written, the 32-bit count is zero",
              r.get("missing") == str(n_x86) and r.get("written") == str(n - n_x86) and r.get("x86") == "0" and r.get("failed") == "0", r)
        check("... and the skipped entries' files are not made", not (menu / "Programs/BCD Tools/Game Controllers.lnk").exists()
              and not (menu / "Programs/BCD Tests/RAM test (32-bit).lnk").exists())
        (bundle / "i386-windows").mkdir()
        stock({"i386-windows"})
        (bundle / "i386-windows" / "ntdll.dll").unlink()
        shutil.rmtree(menu)
        (menu / "Programs").mkdir(parents=True)
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("32-bit test programs alone in i386-windows (no ntdll.dll, so no 32-bit set to link as syswow64) get no entry",
              r.get("missing") == str(n_x86) and r.get("x86") == "0" and r.get("written") == str(n - n_x86), r)
        (bundle / "i386-windows" / "ntdll.dll").write_bytes(b"MZ")
        shutil.rmtree(menu)
        (menu / "Programs").mkdir(parents=True)
        (bundle / "arm64ec-windows" / "d3d10-cube-x64.exe").unlink()
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("an entry whose program is not in the app is skipped", r.get("written") == str(n - 1) and r.get("missing") == "1", r)
        check("... and its file is not made", not (menu / "Programs/BCD Tests/DirectX 10 test.lnk").exists())
        (bundle / "arm64ec-windows" / "d3d10-cube-x64.exe").write_bytes(b"MZ")

        # where a program is found: the 64-bit farms first, the 32-bit set after, and the flag forces the 32-bit one
        (bundle / "aarch64-windows" / "both.exe").write_bytes(b"MZ")
        (bundle / "i386-windows" / "both.exe").write_bytes(b"MZ")
        (bundle / "i386-windows" / "only32.exe").write_bytes(b"MZ")
        (bundle / "arm64ec-windows" / "only64.exe").write_bytes(b"MZ")
        for prog, flags, want in (("both.exe", 0, "0"), ("both.exe", 1, "1"), ("only32.exe", 0, "1"), ("only64.exe", 0, "0"),
                                  ("only64.exe", 1, "-1"), ("none.exe", 0, "-1"), ("a/b.exe", 0, "-1"), ("..", 0, "-1"), ("", 0, "-1"),
                                  ("a\\b.exe", 0, "-1")):
            got = run("farm", bundle, prog, flags).stdout.strip()
            check("program_farm(%r, flags %d) = %s" % (prog, flags, want), got == want, got)

        # the folder of build 601: its own shortcuts go, a file of a person's own stays, and so does the folder with it
        retired = [l.split("|") for l in run("retired").stdout.splitlines()]
        check("the shortcuts of build 601's folder are listed as retired, none of them is an entry today",
              retired and all(r_[0] == "Programs/BCD" for r_ in retired) and not any((r_[0], r_[1]) in {(e[0], e[1]) for e in ents} for r_ in retired), retired)
        shutil.rmtree(menu)
        (menu / "Programs").mkdir(parents=True)
        old_dir = menu / "Programs/BCD"
        old_dir.mkdir()
        for r_ in retired:
            run("build", old_dir / (r_[1] + ".lnk"), "C:\\windows\\system32\\old.exe", "Older")
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("an earlier build's BCD shortcuts are removed, the new ones written", r.get("retired") == str(len(retired)) and r.get("written") == str(n), r)
        check("... and the empty folder with them, but not Programs", not old_dir.exists() and (menu / "Programs").is_dir())
        shutil.rmtree(menu)
        (menu / "Programs").mkdir(parents=True)
        old_dir.mkdir()
        run("build", old_dir / (retired[0][1] + ".lnk"), "C:\\windows\\system32\\old.exe", "Older")
        persons = old_dir / (retired[1][1] + ".lnk")
        persons.write_bytes(b"a person's own file")
        (old_dir / (retired[2][1] + ".lnk")).mkdir()
        sym_old = old_dir / (retired[3][1] + ".lnk")
        sym_old.symlink_to(link_target)
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("only the BCD file goes: a person's file, a folder and a symbolic link of the old names stay with their folder",
              r.get("retired") == "1" and persons.read_bytes() == b"a person's own file" and (old_dir / (retired[2][1] + ".lnk")).is_dir()
              and sym_old.is_symlink() and not (old_dir / (retired[0][1] + ".lnk")).exists(), r)
        shutil.rmtree(menu)
        (menu / "Programs").mkdir(parents=True)
        r = fields(run("install", prefix, bundle).stdout.replace(" ", "\n"))
        check("a prefix with no old folder retires nothing", r.get("retired") == "0", r)

        # Internet Explorer waits for Wine Gecko (BCD_START_GECKO): not in the prefix and not among BCD's downloaded files, no entry;
        # either of them, an entry; an entry already written stays
        (bundle / "i386-windows").mkdir(exist_ok=True)
        stock({"arm64ec-windows", "aarch64-windows", "i386-windows"})
        g_prefix = work / "gecko-prefix"
        g_menu = g_prefix / "drive_c/ProgramData/Microsoft/Windows/Start Menu"
        (g_menu / "Programs").mkdir(parents=True)

        def install_in(pfx, extra_env=None):
            env = {k: v for k, v in os.environ.items() if k != "XDG_CACHE_HOME"}
            env.update(extra_env or {})
            return fields(sh([str(drv), "install", str(pfx), str(bundle)], env=env).stdout.replace(" ", "\n"))

        ie = g_menu / "Programs/BCD Tools/Internet Explorer.lnk"
        r = install_in(g_prefix)
        n_all = len(ents)
        check("without Wine Gecko Internet Explorer gets no entry (counted as missing); every other entry is written",
              r.get("missing") == "1" and r.get("written") == str(n_all - 1) and not ie.exists(), r)
        cache = work / "cache"
        (cache / "wine").mkdir(parents=True)
        r = install_in(g_prefix, {"XDG_CACHE_HOME": str(cache)})
        check("an XDG_CACHE_HOME with no Gecko file in its wine folder does not count", r.get("missing") == "1" and not ie.exists(), r)
        (cache / "wine" / "wine-gecko-2.47.4-x86.msi").write_bytes(b"x")
        r = install_in(g_prefix, {"XDG_CACHE_HOME": str(cache)})
        check("BCD's downloaded Gecko (a wine-gecko-*.msi in XDG_CACHE_HOME/wine) gives the entry, in the 32-bit set",
              r.get("missing") == "0" and r.get("written") == "1" and ie.is_file()
              and fields(run("load", ie).stdout).get("path") == "C:\\windows\\syswow64\\iexplore.exe", r)
        r = install_in(g_prefix)
        check("... and an entry already written stays when the cache is gone (it is only not made)", r.get("missing") == "1" and ie.is_file() and r.get("failed") == "0", r)
        shutil.rmtree(g_menu)
        (g_menu / "Programs").mkdir(parents=True)
        (g_prefix / "drive_c/windows/syswow64/gecko").mkdir(parents=True)
        r = install_in(g_prefix)
        check("Gecko installed in the prefix (syswow64\\gecko, as Wine's installer puts the 32-bit one) gives the entry too", r.get("missing") == "0" and ie.is_file(), r)
        shutil.rmtree(g_prefix / "drive_c/windows/syswow64/gecko")
        (cache / "wine" / "readme.txt").write_bytes(b"x")
        (cache / "wine" / "wine-gecko-2.47.4-x86.msi").unlink()
        (cache / "wine" / "wine-gecko-.msi").write_bytes(b"x")
        shutil.rmtree(g_menu)
        (g_menu / "Programs").mkdir(parents=True)
        r = install_in(g_prefix, {"XDG_CACHE_HOME": str(cache)})
        check("a file that only looks like Gecko's (no version in the name) does not count", r.get("missing") == "1" and not ie.exists(), r)

        # a prefix without the public Start Menu folder gets nothing
        bare = work / "bare"
        (bare / "drive_c").mkdir(parents=True)
        r = fields(run("install", bare, bundle).stdout.replace(" ", "\n"))
        check("a prefix without the template's Start Menu folder gets nothing, and none is made",
              r.get("no_menu") == "1" and r.get("written") == "0" and not (bare / "drive_c/ProgramData").exists(), r)
        garbage_files = files_by_name

        # refused input is refused, a buffer that is too small is never overrun
        check("a target with a non-ASCII byte is refused", run("build", tmp / "x.lnk", "C:\\caf\u00e9.exe", "d").returncode == 1)
        check("an empty target is refused", run("build", tmp / "x.lnk", "", "d").returncode == 1)
        small = run("small")
        check("every buffer smaller than the link is refused, every large enough one gets the same bytes, nothing is written past it",
              small.stdout.startswith("bad=0 "), small.stdout + small.stderr)
        garbage = tmp / "garbage.lnk"
        garbage.write_bytes(garbage_files["Explorer"].read_bytes()[:90])
        check("a truncated link is read as not a link", run("owner", garbage).stdout.strip() == "-1")
        garbage.write_bytes(b"\0" * 200)
        check("zero bytes are read as not a link", run("owner", garbage).stdout.strip() == "-1")
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# ---------------------------------------------------------------- 3. the session
bridge = (APP / "WineProcessBridge.m").read_text()
check("WineProcessBridge.m includes the module", '#include "BCDStartMenu.h"' in bridge or '#import "BCDStartMenu.h"' in bridge)
call = bridge.find("bcd_startmenu_install(")
check("the session calls bcd_startmenu_install once", bridge.count("bcd_startmenu_install(") == 1 and call > 0)
block = bridge[max(0, call - 1800):call + 900]
check("only a desktop session (MADEIRA_DESKTOP=1) gets the files", 'getenv("MADEIRA_DESKTOP")' in block)
check("a BCD Dock session (MADEIRA_DOCK_SESSION=1) does not: Valve's client and its games run there", 'getenv("MADEIRA_DOCK_SESSION")' in block
      and "!(dockSession && dockSession[0] == '1')" in block)
check("env.MADEIRA_START_MENU = 0 leaves them out", 'getenv("MADEIRA_START_MENU")' in block)
check("the call sits after the shell-folder repairs, before the VC++ overlay",
      bridge.index("[shell-dir] user folders for") < call < bridge.index("Layer Microsoft's real VC++ Runtime DLLs"))
check("the result is logged", "[start-menu]" in block)

# The user's own Start Menu folder (build 598). Battle.net on build 597: pressing the Start button read address 0 in Wine's
# explorer (0x1400192cc, fill_menu) and the session ended, because the user's half of the menu had no folder while the public
# half had entries. The template's registry puts the user's Start Menu under %USERPROFILE% and ships the folder for its own
# user only, so the session makes it for the running user like the other profile folders.
import tarfile
with tarfile.open(APP / "prefix-template.tar.gz") as tf:
    names_t = tf.getnames()
    user_reg = tf.extractfile("prefix/user.reg").read().decode("utf-8", "replace")
usf = user_reg[user_reg.index("[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Explorer\\\\User Shell Folders]"):]
usf = usf[:usf.index("\n\n")]
check("the template's User Shell Folders put the user's Start Menu under %USERPROFILE%",
      '"Start Menu"=str(2):"%USERPROFILE%\\\\AppData\\\\Roaming\\\\Microsoft\\\\Windows\\\\Start Menu"' in usf, usf[:600])
tpl_users = sorted({n.split("/")[3] for n in names_t if n.startswith("prefix/drive_c/users/") and n.count("/") >= 4})
with_menu = sorted({n.split("/")[3] for n in names_t
                    if n.startswith("prefix/drive_c/users/") and "/AppData/Roaming/Microsoft/Windows/Start Menu" in n})
check("the template has a user Start Menu only for its own user, not for the device's user (mobile)",
      "mobile" not in with_menu and with_menu, f"users {tpl_users}, with a Start Menu {with_menu}")
uf = bridge.index("[shell-dir] user folders for")
ublock = bridge[bridge.rindex("NSArray *rels = @[", 0, uf):uf]
check("the session makes the user's Start Menu\\Programs with the other profile folders",
      '@"AppData/Roaming/Microsoft/Windows/Start Menu/Programs"' in ublock)
check("an existing folder (or a link that resolves) is left alone",
      "if (!S_ISLNK(lst.st_mode) || stat(cp, &tgt) == 0) continue;" in ublock)
check("the log line says the Start Menu is part of it",
      '"[shell-dir] user folders for %s: %d created (Start Menu included)\\n"' in bridge)

# ---------------------------------------------------------------- 4. the project
pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
check("the Xcode project compiles BCDStartMenu.c and lists the header",
      "BCDStartMenu.c in Sources" in pbx and "BCDStartMenu.h" in pbx and pbx.count("BCDStartMenu.c") >= 4)
for f in ("BCDStartMenu.c", "BCDStartMenu.h"):
    head = (APP / f).read_text()[:400]
    check(f + " has the BCD licence header", "SPDX-License-Identifier: GPL-3.0-only" in head and "LICENSE-BCD.md" in head)
build_script = R / "tools/build-dx-tests.sh"
d3d12_script = (R / "tools/build-madeira-d3d12-dll.sh").read_text()
bs = build_script.read_text() if build_script.exists() else ""
check("tools/build-dx-tests.sh builds d3d9, d3d10 and d3d11 as <api>-cube-x64.exe", "for t in d3d9 d3d10 d3d11; do" in bs and '"$t-cube-x64.exe"' in bs)
for prog in ("d3d9-cube-x64.exe", "d3d10-cube-x64.exe", "d3d11-cube-x64.exe"):
    check(prog + " is tracked in arm64ec-windows, with its source in tests/dxtests",
          (APP / "arm64ec-windows" / prog).is_file() and (R / "tests/dxtests" / (prog.split("-")[0] + "_cube.c")).is_file())
check("d3d12-cube-x64.exe is built by tools/build-madeira-d3d12-dll.sh and tracked", "d3d12-cube-x64.exe" in d3d12_script
      and (APP / "arm64ec-windows/d3d12-cube-x64.exe").is_file())
check("explorer.exe is in the app's aarch64-windows folder", (APP / "aarch64-windows/explorer.exe").is_file())
# round 603: the programs of the extra table are in the folders the install looks in (winecfg in the aarch64 set; 7-Zip and the runtime
# installer are tracked in arm64ec-windows; control.exe and appwiz.cpl are in the 32-bit set, which is built by CI and not tracked)
check("winecfg.exe is in the app's aarch64-windows folder", (APP / "aarch64-windows/winecfg.exe").is_file())
check("7zFM.exe, 7z.exe and bcd-runtimes-x64.exe are tracked in arm64ec-windows",
      all((APP / "arm64ec-windows" / n).is_file() for n in ("7zFM.exe", "7z.exe", "bcd-runtimes-x64.exe")))
wf = (R / ".github/workflows/build-ipa.yml").read_text()
check("the workflow runs this check", "tests/host/check-bcd-startmenu.py" in wf)

sys.exit(0 if ok else 1)
