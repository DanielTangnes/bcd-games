#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Builds 7-Zip for the Wine desktop's Start menu from the pinned source (round 603).

  7zFM.exe   the 7-Zip File Manager (a Windows GUI program, every archive format built in, no 7z.dll needed)
  7z.exe     the command-line program (7-Zip's "7zz" bundle, Bundles/Alone2)

Both are x86-64 Windows programs (the emulated kind, like BCD's other test programs), built with the tracked llvm-mingw from
third-party/7zip/7z2605-src.tar.xz, the unmodified release of the project (ip7z/7zip, tag 26.05), checked against its SHA-256
before anything is unpacked. They are separate programs that BCD starts from the Start menu; nothing of 7-Zip is linked into BCD.

The RAR code is left out, exactly as 7-Zip's own makefile.gcc does with DISABLE_RAR=1 (and DISABLE_RAR_COMPRESS=1): no
RarHandler/Rar5Handler, no Rar1/2/3/5 decoder, no Rar crypto. That code is "LGPL with the unRAR licence restriction"; without it
everything that ships is plain LGPL-2.1-or-later (plus the BSD-licensed LZFSE/Zstandard decoders and Xxh64, see 7-Zip's License.txt),
and .rar archives are not supported.

The object lists are not typed in here: they are read from 7-Zip's own nmake makefiles (Bundles/Fm/makefile and
Bundles/Alone2/makefile with the .mak files they include), so the set of sources is the project's. What 7-Zip's Windows makefiles
get from assembler on x64 comes from the C versions here (the list of 7zip_gcc.mak's non-assembler branch). No source file is changed.
Two things come from outside the source: tools/7zip-shim.c (HtmlHelpW, because Wine has no 64-bit hhctrl.ocx and the help file is
not shipped) and the llvm-mingw runtime, linked statically (-static) so that no libc++.dll is needed.

  MINGW=<llvm-mingw bin dir>   default <repo>/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin
  SHIP_DIR=<dir>               default <repo>/app/Madeira/arm64ec-windows (a session's C:\\windows\\system32)
  WORK=<dir>                   default <repo>/build/7zip
  JOBS=<n>                     compile jobs, default 3
  ONLY=fm|console              build one of the two
  ARCH=x64|arm64ec             the machine: x64 (the default, an emulated program like BCD's other Windows programs) or arm64ec (native
                               code; not shipped, an experiment for the device: SHIP_DIR should then be a scratch folder)

With no llvm-mingw the script says so and exits 0 (the tracked programs stay). Run from anywhere; --list prints the sources and
exits (the host check uses it). Exit code 1: the build or one of the checks of its result failed.
"""
import concurrent.futures as cf
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARBALL = os.path.join(ROOT, "third-party", "7zip", "7z2605-src.tar.xz")
PINNED_SHA256 = "0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e"
SHIM = os.path.join(ROOT, "tools", "7zip-shim.c")

# 7-Zip's makefile.gcc, non-assembler branch: the optimised code that nmake gets from .asm files on x64 comes from C files.
EXTRA_C = ["7zCrcOpt", "XzCrc64Opt", "Sha1Opt", "Sha256Opt", "Sort", "AesOpt", "LzFindOpt"]

# nmake group -> directory below the source root (7zip.mak's rules)
GROUP_DIRS = {
    "COMMON_OBJS": "CPP/Common",
    "WIN_OBJS": "CPP/Windows",
    "WIN_CTRL_OBJS": "CPP/Windows/Control",
    "7ZIP_COMMON_OBJS": "CPP/7zip/Common",
    "UI_COMMON_OBJS": "CPP/7zip/UI/Common",
    "AGENT_OBJS": "CPP/7zip/UI/Agent",
    "CONSOLE_OBJS": "CPP/7zip/UI/Console",
    "EXPLORER_OBJS": "CPP/7zip/UI/Explorer",
    "FM_OBJS": "CPP/7zip/UI/FileManager",
    "GUI_OBJS": "CPP/7zip/UI/GUI",
    "AR_COMMON_OBJS": "CPP/7zip/Archive/Common",
    "AR_OBJS": "CPP/7zip/Archive",
    "7Z_OBJS": "CPP/7zip/Archive/7z",
    "CAB_OBJS": "CPP/7zip/Archive/Cab",
    "CHM_OBJS": "CPP/7zip/Archive/Chm",
    "COM_OBJS": "CPP/7zip/Archive/Com",
    "ISO_OBJS": "CPP/7zip/Archive/Iso",
    "NSIS_OBJS": "CPP/7zip/Archive/Nsis",
    "RAR_OBJS": "CPP/7zip/Archive/Rar",
    "TAR_OBJS": "CPP/7zip/Archive/Tar",
    "UDF_OBJS": "CPP/7zip/Archive/Udf",
    "WIM_OBJS": "CPP/7zip/Archive/Wim",
    "ZIP_OBJS": "CPP/7zip/Archive/Zip",
    "COMPRESS_OBJS": "CPP/7zip/Compress",
    "CRYPTO_OBJS": "CPP/7zip/Crypto",
    "C_OBJS": "C",
}
GROUP_ORDER = list(GROUP_DIRS)

# What each program is: nmake file, extra compile flags, link flags, libraries, resource file, subsystem (PE value).
PROGRAMS = {
    "fm": dict(name="7zFM.exe", makefile="CPP/7zip/Bundles/Fm/makefile", rc_dir="CPP/7zip/Bundles/Fm",
               cflags=["-DZ7_LANG", "-DZ7_DEVICE_FILE"], ldflags=["-mwindows"], subsystem=2,
               libs=["-loleaut32", "-luuid", "-ladvapi32", "-luser32", "-lole32", "-lgdi32", "-lcomctl32", "-lcomdlg32",
                     "-lshell32", "-lmpr"], shim=True),
    "console": dict(name="7z.exe", makefile="CPP/7zip/Bundles/Alone2/makefile", rc_dir="CPP/7zip/Bundles/Alone2",
                    cflags=["-DZ7_PROG_VARIANT_Z", "-DZ7_DEVICE_FILE", "-D_CONSOLE"], ldflags=["-mconsole"], subsystem=3,
                    libs=["-loleaut32", "-luuid", "-ladvapi32", "-luser32", "-lole32", "-lshell32"], shim=False),
}

# DLLs a built program may import (system DLLs every Wine session has) -- anything else, libc++.dll above all, is an error.
ALLOWED_IMPORTS = {"kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll", "shell32.dll", "ole32.dll", "oleaut32.dll",
                   "comctl32.dll", "comdlg32.dll", "mpr.dll"}


# ---------------------------------------------------------------- nmake lists

def read_logical_lines(path):
    """The makefile's lines without their recipes, backslash continuations joined."""
    out, cur = [], ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\r\n")
            if line.startswith("\t"):
                continue
            if cur:
                line = cur + " " + line.strip()
                cur = ""
            if line.endswith("\\"):
                cur = line[:-1].rstrip()
                continue
            out.append(line)
    if cur:
        out.append(cur)
    return out


class Env:
    def __init__(self, cwd):
        self.v = {"O": "@O@"}
        self.cwd = cwd

    def expand(self, s):
        for _ in range(20):
            n = re.sub(r"\$\(([A-Za-z0-9_]+)\)", lambda m: self.v.get(m.group(1), ""), s)
            n = re.sub(r"\$O(?![A-Za-z0-9_(])", "@O@", n)
            if n == s:
                break
            s = n
        return s


def eval_if(expr, env):
    expr = env.expand(expr).replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r'"([^"]*)"\s*==\s*"([^"]*)"', lambda m: str(m.group(1) == m.group(2)), expr)
    expr = re.sub(r'"([^"]*)"\s*!=\s*"([^"]*)"', lambda m: str(m.group(1) != m.group(2)), expr)
    if not re.fullmatch(r"[\sA-Za-z()]*", expr):
        return False
    try:
        return bool(eval(expr, {"__builtins__": {}}, {"True": True, "False": False}))
    except Exception:
        return False


def evaluate(path, env):
    """Runs a makefile's assignments, includes and conditionals; PLATFORM is not set, as for a build without a platform name."""
    stack = []
    for line in read_logical_lines(path):
        l = line.strip()
        if not l or l.startswith("#"):
            continue
        active = all(a for a, _ in stack)
        if l.startswith("!"):
            m = re.match(r"!\s*(\w+)\s*(.*)", l)
            d, rest = m.group(1).upper(), m.group(2).strip()
            if d == "INCLUDE":
                if active:
                    inc = rest.strip('"')
                    cand = os.path.normpath(os.path.join(env.cwd, inc))
                    if not os.path.exists(cand):
                        cand = os.path.normpath(os.path.join(os.path.dirname(path), inc))
                    if os.path.exists(cand):
                        evaluate(cand, env)
            elif d == "IFDEF":
                c = rest in env.v
                stack.append((c, c))
            elif d == "IFNDEF":
                c = rest not in env.v
                stack.append((c, c))
            elif d == "IF":
                c = eval_if(rest, env)
                stack.append((c, c))
            elif d == "ELSEIF":
                _, taken = stack.pop()
                c = (not taken) and eval_if(rest, env)
                stack.append((c, taken or c))
            elif d == "ELSE":
                _, taken = stack.pop()
                stack.append((not taken, True))
            elif d == "ENDIF":
                stack.pop()
            continue
        if not active:
            continue
        m = re.match(r"([A-Za-z0-9_]+)\s*=\s*(.*)$", l)
        if m:
            env.v[m.group(1)] = env.expand(m.group(2))


def is_rar(name):
    return name.startswith("Rar")


def source_list(src, which):
    """[(group, name, path)] of one program's sources: the nmake lists, without the RAR code, plus the C versions of the optimised code."""
    p = PROGRAMS[which]
    mk = os.path.join(src, p["makefile"])
    env = Env(os.path.dirname(mk))
    evaluate(mk, env)
    jobs = []
    for g in GROUP_ORDER:
        if g == "RAR_OBJS":
            continue                                    # RarHandler, Rar5Handler: DISABLE_RAR
        for n in re.findall(r"@O@\\([^\s\\]+)\.obj", env.v.get(g, "")):
            if g in ("COMPRESS_OBJS", "CRYPTO_OBJS") and is_rar(n):
                continue                                # the Rar decoders and Rar crypto: DISABLE_RAR / DISABLE_RAR_COMPRESS
            ext = ".c" if g == "C_OBJS" else ".cpp"
            jobs.append((g, n, os.path.join(src, GROUP_DIRS[g], n + ext)))
    have = {n for g, n, _ in jobs if g == "C_OBJS"}
    for n in EXTRA_C:
        if n not in have:
            jobs.append(("C_OBJS", n, os.path.join(src, "C", n + ".c")))
    return jobs


# ---------------------------------------------------------------- source, build, checks

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def unpack(work):
    got = sha256_file(TARBALL)
    sums = open(os.path.join(os.path.dirname(TARBALL), "SHA256SUMS")).read().split()
    if got != PINNED_SHA256 or sums[0] != PINNED_SHA256:
        sys.exit("build-7zip: %s is not the pinned release (%s, SHA256SUMS %s)" % (TARBALL, got, sums[0]))
    src = os.path.join(work, "src")
    if os.path.isdir(src):
        shutil.rmtree(src)
    os.makedirs(src)
    with tarfile.open(TARBALL, "r:xz") as t:
        for m in t.getmembers():                                   # nothing but plain files and folders below src
            name = os.path.normpath(m.name)
            if not (m.isfile() or m.isdir()) or os.path.isabs(name) or name.startswith(".."):
                sys.exit("build-7zip: refusing the archive member %r" % m.name)
        t.extractall(src)
    return src


def machine_and_imports(path):
    data = open(path, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0", "not a PE image"
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    subsystem = struct.unpack_from("<H", data, opt + 68)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    secs = opt + struct.unpack_from("<H", data, pe + 20)[0]
    sections = [struct.unpack_from("<8sIIII", data, secs + 40 * i) for i in range(nsec)]

    def r2o(rva):
        for _, vsize, vaddr, rsize, roff in sections:
            if vaddr <= rva < vaddr + max(vsize, rsize):
                return roff + rva - vaddr
        raise AssertionError("rva %#x is in no section" % rva)

    dd = opt + (112 if magic == 0x20B else 96)
    names, o = [], r2o(struct.unpack_from("<I", data, dd + 8)[0])
    while True:
        f = struct.unpack_from("<IIIII", data, o)
        if f[3] == 0:
            break
        n = r2o(f[3])
        names.append(data[n:data.index(b"\0", n)].decode().lower())
        o += 20
    return machine, subsystem, names, data


def check_pe(path, subsystem, farm):
    machine, sub, names, data = machine_and_imports(path)
    assert machine == 0x8664, "machine %#x is not x86-64" % machine
    assert sub == subsystem, "subsystem %d, wanted %d" % (sub, subsystem)
    bad = [n for n in names if n not in ALLOWED_IMPORTS and not n.startswith("api-ms-win-crt-")]
    assert not bad, "imports outside the allowed set: %s" % bad
    if farm and os.path.exists(os.path.join(farm, "ntdll.dll")):
        have = {f.lower() for f in os.listdir(farm)}
        missing = [n for n in names if not n.startswith("api-ms-win-") and n not in have]
        assert not missing, "imports the farm %s does not have: %s" % (farm, missing)
    assert b"unRAR" not in data and b"NRar" not in data, "RAR code is in the program"


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build(which, src, work, mingw, ship, jobs_n, arch="x64"):
    p = PROGRAMS[which]
    out = os.path.join(work, "o-" + which)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    triple = "x86_64-w64-mingw32" if arch == "x64" else "arm64ec-w64-mingw32"
    cc, cxx = mingw + "/" + triple + "-clang", mingw + "/" + triple + "-clang++"
    windres = mingw + "/" + triple + "-windres"
    jobs = source_list(src, which)
    print("== %s: %d sources" % (p["name"], len(jobs)), flush=True)

    def compile_one(job):
        g, n, f = job
        if not os.path.exists(f):
            return job, "missing source " + f
        o = os.path.join(out, "%s__%s.o" % (g, n))
        cmd = ([cc, "-O2"] if f.endswith(".c") else [cxx, "-O2", "-std=gnu++17"])
        cmd += ["-c", "-w", "-DNDEBUG"] + p["cflags"]
        if arch != "x64":
            cmd += ["-include", "stdio.h"]          # C/Sha512.c's ARM path calls printf without including it
        cmd += ["-o", o, f]
        r = run(cmd, cwd=os.path.dirname(f))
        return job, (None if r.returncode == 0 else r.stderr[-2000:])

    failed = []
    with cf.ThreadPoolExecutor(jobs_n) as ex:
        for job, err in ex.map(compile_one, jobs):
            if err:
                failed.append((job, err))
                print("FAILED %s\n%s" % (job[2], err), flush=True)
    if failed:
        return False
    objs = sorted(os.path.join(out, f) for f in os.listdir(out) if f.endswith(".o"))

    res = os.path.join(out, "resource.o")
    rc = os.path.join(src, p["rc_dir"])
    r = run([windres, "-O", "coff", "-I", ".", "-I", "../../UI/FileManager", "-I", "../../UI/GUI", "resource.rc", "-o", res], cwd=rc)
    if r.returncode != 0:
        print("FAILED resource.rc\n" + r.stderr[-2000:])
        return False
    objs.append(res)
    if p["shim"]:
        shim = os.path.join(out, "bcd-shim.o")
        r = run([cc, "-O2", "-c", "-o", shim, SHIM])
        if r.returncode != 0:
            print("FAILED the shim\n" + r.stderr[-2000:])
            return False
        objs.append(shim)

    exe = os.path.join(work, p["name"])
    r = run([cxx, "-static", "-s", "-Wl,--no-insert-timestamp"] + p["ldflags"] + ["-o", exe] + objs + p["libs"])
    if r.returncode != 0:
        print("FAILED link\n" + r.stderr[-3000:])
        return False
    try:
        check_pe(exe, p["subsystem"], ship)
    except AssertionError as e:
        print("FAILED the check of %s: %s" % (p["name"], e))
        return False
    os.makedirs(ship, exist_ok=True)
    shutil.copyfile(exe, os.path.join(ship, p["name"]))
    print("::notice::%s built (%d bytes) and shipped" % (p["name"], os.path.getsize(exe)))
    return True


def main():
    work = os.environ.get("WORK", os.path.join(ROOT, "build", "7zip"))
    ship = os.environ.get("SHIP_DIR", os.path.join(ROOT, "app", "Madeira", "arm64ec-windows"))
    mingw = os.environ.get("MINGW", os.path.join(ROOT, "toolchains", "llvm-mingw-20260421-ucrt-macos-universal", "bin"))
    jobs_n = int(os.environ.get("JOBS", "3"))
    only = os.environ.get("ONLY", "")
    arch = os.environ.get("ARCH", "x64")
    if arch not in ("x64", "arm64ec"):
        sys.exit("build-7zip: ARCH is x64 or arm64ec")
    if "--list" in sys.argv:
        os.makedirs(work, exist_ok=True)
        src = unpack(work)
        for which in ("fm", "console"):
            for g, n, f in source_list(src, which):
                print(which, g, os.path.relpath(f, src))
        return 0
    if not os.path.exists(mingw + "/x86_64-w64-mingw32-clang++"):
        print("::warning::build-7zip: no llvm-mingw at %s -- keeping the tracked 7-Zip programs" % mingw)
        return 0
    try:
        os.nice(10)
    except OSError:
        pass
    os.makedirs(work, exist_ok=True)
    src = unpack(work)
    ok = True
    for which in ("fm", "console"):
        if only and only != which:
            continue
        ok = build(which, src, work, mingw, ship, jobs_n, arch) and ok
    if not ok:
        print("::warning::build-7zip: a 7-Zip program did not build -- keeping the tracked programs")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
