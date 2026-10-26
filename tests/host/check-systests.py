#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""BCD's system tests (tests/systests, the Start menu's "BCD Tests"): RAM test 2/4/6/8/12 GB, RAM test (32-bit), JIT pool test, CPU test,
system info, VC++ and .NET check, disk speed, network test, "Run all tests".

One Windows program, bcd-systest-x64.exe in arm64ec-windows (a session's C:\\windows\\system32) and bcd-systest-x86.exe in i386-windows
(C:\\windows\\syswow64), told what to do by its first argument. Checks:
  1. core.h (the logic that needs no Windows) is built on the Mac with ASan/UBSan and core_test.c runs: the key=value text of the
     host files, the processor's features and x86-64 level from canned CPUID leaves, the Visual C++ table, and above all the RAM
     test's loop (ram_drive) against thousands of made-up devices (limits from 1.5 to 12 GB, any start, piece size, speed, a
     background process that grows, a host that updates every quarter of a second, every two seconds or never): the app is never taken
     past its limit, the test stops close to it, and a host that stops answering ends the run.
  2. The program builds with llvm-mingw for both machines with -Wall -Wextra -Werror, the PE headers are right (x86-64 and i386, the
     GUI subsystem, large-address-aware for the 32-bit one, imports of kernel32, user32, gdi32, advapi32 and the C runtime only, the
     32-bit one's imports in the i386 farm when that is there), and the tracked binaries are what the source builds to
     (tools/build-systests.sh is deterministic).
  3. The source keeps its promises: every test the Start menu starts is one the program knows, each test ends in a RESULT line and the
     log gets every line ("[systest] ..." on standard error in one write, the same text in C:\\ProgramData\\BCD\\bcd-systest.log), the
     RAM test goes through ram_drive and frees what it took, the disk test only creates its own uniquely named files (CREATE_NEW,
     never over anything) and removes them, nothing else is created, overwritten or deleted, and the JIT pool test allocates nothing
     in the pool (it reads the environment and a file).
  4. The tracked binaries sit where the Start menu entries look for them; the workflow builds and checks the tests.
"""
import hashlib
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


def pe_info(path):
    data = Path(path).read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0"
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    characteristics = struct.unpack_from("<H", data, pe + 22)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    subsystem = struct.unpack_from("<H", data, opt + 68)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    secs = opt + struct.unpack_from("<H", data, pe + 20)[0]
    sections = [struct.unpack_from("<8sIIII", data, secs + 40 * i) for i in range(nsec)]

    def rva2off(rva):
        for _, vsize, vaddr, rsize, roff in sections:
            if vaddr <= rva < vaddr + max(vsize, rsize):
                return roff + rva - vaddr
        raise AssertionError("rva not in a section")

    dd = opt + (112 if magic == 0x20B else 96)
    imp = struct.unpack_from("<I", data, dd + 8)[0]
    names = []
    o = rva2off(imp)
    while True:
        f = struct.unpack_from("<IIIII", data, o)
        if f[3] == 0:
            break
        n = rva2off(f[3])
        names.append(data[n:data.index(b"\0", n)].decode().lower())
        o += 20
    stamp = struct.unpack_from("<I", data, pe + 8)[0]
    return {"machine": machine, "magic": magic, "subsystem": subsystem, "laa": bool(characteristics & 0x20), "imports": names, "stamp": stamp}


ALLOWED = {"kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll"}

# ---------------------------------------------------------------- 1. core.h on the Mac
tmp = Path(tempfile.mkdtemp(prefix="bcd-systests-"))
try:
    san = []
    probe = sh(["clang", "-fsanitize=address,undefined", "-x", "c", "-", "-o", str(tmp / "probe")], input="int main(void){return 0;}")
    if probe.returncode == 0 and sh([str(tmp / "probe")]).returncode == 0:
        san = ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"]
    else:
        note("clang has no working sanitizers here; core_test runs without them")
    b = sh(["clang", "-std=gnu11", "-Wall", "-Wextra", "-Werror", *san, "-O1", "-g", "-I", str(SYS), str(SYS / "core_test.c"), "-o", str(tmp / "core_test")])
    check("core.h and core_test.c build with -Wall -Wextra -Werror" + (" and ASan/UBSan" if san else ""), b.returncode == 0, b.stderr)
    if b.returncode == 0:
        t = sh([str(tmp / "core_test")], timeout=600)
        last = t.stdout.strip().splitlines()[-1] if t.stdout.strip() else ""
        m = re.match(r"(\d+) checks, 0 failed", last)
        check("core_test: the host text, the CPU levels, the Visual C++ table and the RAM loop against made-up devices all hold",
              t.returncode == 0 and m is not None and int(m.group(1)) > 4000, t.stdout[-2500:] + t.stderr[-1000:])
finally:
    pass

# ---------------------------------------------------------------- 2. the program, built with llvm-mingw
mingw = None
for cand in (os.environ.get("MINGW"), str(R / "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"),
             str(Path.home() / "madeira-bcd/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin")):
    if cand and (Path(cand) / "x86_64-w64-mingw32-clang").exists():
        mingw = Path(cand)
        break
tracked64 = APP / "arm64ec-windows/bcd-systest-x64.exe"
tracked32 = APP / "i386-windows/bcd-systest-x86.exe"
check("the tracked programs exist: x64 in arm64ec-windows, x86 in i386-windows", tracked64.is_file() and tracked32.is_file())
for path, machine, magic, laa in ((tracked64, 0x8664, 0x20B, None), (tracked32, 0x14C, 0x10B, True)):
    if not path.is_file():
        continue
    p = pe_info(path)
    check(path.name + ": the right machine, a GUI program" + (", large-address-aware" if laa else ""),
          p["machine"] == machine and p["magic"] == magic and p["subsystem"] == 2 and (laa is None or p["laa"] == laa), p)
    check(path.name + ": imports Windows' own DLLs and the C runtime only (everything else is loaded at run time)",
          p["imports"] and all(n in ALLOWED or n.startswith("api-ms-win-crt-") for n in p["imports"]), p["imports"])
    check(path.name + ": no build time in the header (a build is the same bytes every time)", p["stamp"] == 0, p["stamp"])

farm = Path.home() / "madeira-bcd/app/Madeira/i386-windows"
if farm.is_dir() and (farm / "ntdll.dll").exists() and tracked32.is_file():
    have = {f.lower() for f in os.listdir(farm)}
    missing = [n for n in pe_info(tracked32)["imports"] if not n.startswith("api-ms-win-") and n not in have]
    check("bcd-systest-x86.exe: everything it imports is in the 32-bit farm of the build tree", not missing, missing)
    farm64 = Path.home() / "madeira-bcd/app/Madeira/arm64ec-windows"
    have64 = {f.lower() for f in os.listdir(farm64)} if farm64.is_dir() else set()
    if have64:
        missing = [n for n in pe_info(tracked64)["imports"] if not n.startswith("api-ms-win-") and n not in have64]
        check("bcd-systest-x64.exe: everything it imports is in the arm64ec farm of the build tree", not missing, missing)
else:
    note("no 32-bit farm in ~/madeira-bcd: the program's imports were not compared with it")


# Every function the programs import must be exported by the farm's DLL (a missing one ends the program in the loader, before its
# first line): kernel32, user32, gdi32 and advapi32 by name, and the C runtime's api-ms-win-crt-* contracts through ucrtbase.dll.
def objdump_tool():
    for cand in (os.environ.get("MINGW"), str(R / "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"),
                 str(Path.home() / "madeira-bcd/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin")):
        if cand and (Path(cand) / "llvm-objdump").exists():
            return str(Path(cand) / "llvm-objdump")
    return None


def pe_imports(tool, exe):
    out = sh([tool, "-p", str(exe)]).stdout
    imps, cur = {}, None
    for line in out.splitlines():
        m = re.match(r"\s*DLL Name: (\S+)", line)
        if m:
            cur = m.group(1).lower()
            imps[cur] = []
            continue
        m = re.match(r"^\s+(\d+)\s+(\S+)\s*$", line)
        if cur and m:
            imps[cur].append(m.group(2))
    return imps


def pe_exports(tool, dll):
    names, inexp = set(), False
    for line in sh([tool, "-p", str(dll)]).stdout.splitlines():
        if "Ordinal" in line and "RVA" in line:
            inexp = True
            continue
        if inexp:
            m = re.match(r"^\s+\d+\s+(?:0x[0-9a-fA-F]+\s+)?(\S+)", line)
            if m:
                names.add(m.group(1))
    return names


tool = objdump_tool()
for exe, fdir in ((tracked64, Path.home() / "madeira-bcd/app/Madeira/arm64ec-windows"), (tracked32, Path.home() / "madeira-bcd/app/Madeira/i386-windows")):
    if tool and exe.is_file() and (fdir / "ucrtbase.dll").exists():
        gone, exports = [], {}
        for dll, funcs in pe_imports(tool, exe).items():
            target = "ucrtbase.dll" if dll.startswith("api-ms-win-crt-") else dll
            if not (fdir / target).exists():
                gone.append(dll)
                continue
            exports.setdefault(target, pe_exports(tool, fdir / target))
            gone += [dll + "!" + f for f in funcs if f not in exports[target]]
        check(exe.name + ": every function it imports is exported by the farm's DLL (" + fdir.parent.parent.name + "/" + fdir.name + ")", not gone, gone)
    else:
        note("no farm or no llvm-objdump here: %s's imported functions were not compared with the farm's exports" % exe.name)

if mingw is None:
    note("no llvm-mingw here (toolchains/ or ~/madeira-bcd/toolchains): the program was not rebuilt and compared with the tracked binaries")
else:
    out64, out32 = tmp / "ship64", tmp / "ship32"
    env = dict(os.environ, MINGW=str(mingw), SHIP_DIR=str(out64), SHIP_DIR32=str(out32))
    b = sh(["bash", str(R / "tools/build-systests.sh")], cwd=R, env=env)
    check("tools/build-systests.sh builds both programs (no warning that one did not build)",
          b.returncode == 0 and "did not build" not in b.stdout and (out64 / "bcd-systest-x64.exe").is_file() and (out32 / "bcd-systest-x86.exe").is_file(),
          b.stdout[-2000:] + b.stderr[-1000:])
    for built, tracked in ((out64 / "bcd-systest-x64.exe", tracked64), (out32 / "bcd-systest-x86.exe", tracked32)):
        if built.is_file() and tracked.is_file():
            check(tracked.name + ": the tracked program is what the source builds to (rebuild with tools/build-systests.sh and commit it)",
                  hashlib.sha256(built.read_bytes()).hexdigest() == hashlib.sha256(tracked.read_bytes()).hexdigest())
    # -Werror with the host's own warnings too: the script uses -Wall -Wextra without -Werror so a newer compiler cannot take a build away
    for tgt, extra in (("x86_64-w64-mingw32-clang", []), ("i686-w64-mingw32-clang", ["-Wl,--large-address-aware"])):
        w = sh([str(mingw / tgt), "-O2", "-Wall", "-Wextra", "-Werror", "-mwindows", *extra, "-I", str(SYS), "-o", str(tmp / (tgt + ".exe")), str(SYS / "systest.c"),
                "-ldxguid", "-luuid"])
        check("systest.c builds with -Wall -Wextra -Werror for " + tgt.split("-")[0], w.returncode == 0, w.stderr)

# ---------------------------------------------------------------- 3. the source's promises
src = (SYS / "systest.c").read_text()
core = (SYS / "core.h").read_text()
menu = (APP / "BCDStartMenu.c").read_text()
args = re.findall(r'(?:SYSTEST|SYSTEST_X86),\s+"[^"]*",\s+"([^"]+)"\s*\}', menu)
known = set(re.findall(r'strcmp\(g_job, "(\w+)"\)', src[src.index("static int run_job"):src.index("static DWORD WINAPI worker_main")]))
check("the Start menu starts only tests the program knows: " + ", ".join(sorted(set(a.split()[0] for a in args))),
      args and set(a.split()[0] for a in args) <= known, (sorted(set(a.split()[0] for a in args)), sorted(known)))
check("... and the program knows exactly: all, cpu, ram, ram32, jit, sysinfo, vcrt, disk, net", known == {"all", "cpu", "ram", "ram32", "jit", "sysinfo", "vcrt", "disk", "net"}, known)
sizes = sorted({int(a.split()[1]) for a in args if a.startswith("ram ")})
check("the RAM tests ask for 2, 4, 6, 8 and 12 GB, and the program takes 1 to 32 (512 pieces of 64 MB)", sizes == [2, 4, 6, 8, 12] and "gb == 0 || gb > 32" in src and "#define MAX_CHUNKS 512" in src, sizes)
check("every test ends in a RESULT line (finish): cpu, ram, ram32, jit, sysinfo, vcrt, disk, net",
      all(re.search(r'finish\("%s' % t, src) for t in ("cpu", "ram32", "jit", "sysinfo", "vcrt", "disk", "net")) and "finish(name," in src and 'say("RESULT %s: %s - %s"' in src)
check("the verdicts are PASS, LIMIT, WARN, FAIL and SKIP", all(('"%s"' % v) in core for v in ("PASS", "LIMIT", "WARN", "FAIL", "SKIP")))
emit = src[src.index("static void emit("):src.index("/* A formatted text;")]
check("the log gets every line: '[systest] ' on standard error in one WriteFile, and the same text in bcd-systest.log",
      'memcpy(buf, "[systest] ", 10)' in emit and "GetStdHandle(STD_ERROR_HANDLE)" in emit and emit.count("WriteFile(") == 2 and "g_logfile" in emit
      and '#define LOG_FILE  HOST_DIR "\\\\bcd-systest.log"' in src)
check("... the file is the last run only (CREATE_ALWAYS on that one path)", re.search(r'CreateFileA\(LOG_FILE, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS', src) is not None)
check("'all' ends with the instruction to press Send Log", "Now press Send Log" in src[src.index("static int test_all"):src.index("/* ====", src.index("static int test_all"))])
check("'all' runs the graphics probes last, writes one report table and ends with its own RESULT line",
      src.index("test_net(1);") < src.index("test_sysinfo(1);") < src.index("results_table(summary") < src.index('finish("all", worst, "%s", summary);') < src.index("Now press Send Log"))
ram = src[src.index("static int ram_run"):src.index("static int test_ram(u64 gb)")]
check("the RAM test goes through ram_drive, verifies what it wrote, and gives every piece back (VirtualFree)",
      "ram_drive(&st, &io, &head)" in ram and "check_random(" in ram and "VirtualFree(w.chunks[i], 0, MEM_RELEASE)" in ram)
check("... it takes pieces of 64 MB (32 MB in a 32-bit process) and never asks for more than the chunk table holds",
      "BITS == 64 ? 64 : 32" in ram and "if (w->n >= MAX_CHUNKS) return 0;" in src)
check("... without numbers from the app it stays under a quarter of what Windows thinks the RAM is (at most 2 GB)", "(m.ullTotalPhys >> 20) / 4" in ram and "> 2048" in ram)
check("... the stop is a result of its own (LIMIT), with the device's figure in the sentence", "your device gave %s of the %s asked" in ram and "V_LIMIT" in ram)
check("the 32-bit test keeps 160 MB of the window for the program itself and gives the reservations back",
      "< 160 + chunk_mb" in src and "VirtualFree(res[i], 0, MEM_RELEASE)" in src and "#ifdef _WIN64" in src[src.index("static int test_ram32"):])
disk = src[src.index("static void disk_one"):src.index("static int disk_target")]
calls = re.findall(r"CreateFileA\(([^;]*?)\);", src, re.S)
disp = [re.findall(r"\b(CREATE_NEW|CREATE_ALWAYS|OPEN_ALWAYS|OPEN_EXISTING|TRUNCATE_EXISTING)\b", c)[0] for c in calls]
disk_calls = re.findall(r"CreateFileA\(([^;]*?)\);", disk, re.S)
disk_disp = [re.findall(r"\b(CREATE_NEW|CREATE_ALWAYS|OPEN_ALWAYS|OPEN_EXISTING|TRUNCATE_EXISTING)\b", c)[0] for c in disk_calls]
check("the disk test creates its files with CREATE_NEW only (never over an existing file) and only reads the one it wrote (OPEN_EXISTING)",
      sorted(set(disk_disp)) == ["CREATE_NEW", "OPEN_EXISTING"] and disk_disp.count("CREATE_NEW") == 2, disk_disp)
check("... every other CreateFileA in the program reads (OPEN_EXISTING), and CREATE_ALWAYS is the log file's alone",
      disp.count("CREATE_ALWAYS") == 1 and "TRUNCATE_EXISTING" not in disp and "OPEN_ALWAYS" not in disp
      and re.search(r"CreateFileA\(LOG_FILE, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS", src), disp)
check("... the names are the test's own: bcd-disktest-<process>-<n>.tmp and a folder bcd-disktest-dir-<process>",
      'bcd-disktest-%lu-%d.tmp' in disk and "bcd-disktest-dir-%lu" in disk)
deletes = re.findall(r"(DeleteFileA|RemoveDirectoryA)\((\w+)\)", src)
check("... only those are deleted: every DeleteFileA/RemoveDirectoryA in the program is in the disk test, on its own path variables",
      deletes and all(d[1] in ("path", "sub") for d in deletes) and src.count("DeleteFileA(") == 2 and src.count("RemoveDirectoryA(") == 1
      and all(src.index(x) > src.index("static void disk_one") and src.index(x) < src.index("static int disk_target") for x in ("DeleteFileA(path)", "RemoveDirectoryA(sub)")), deletes)
check("... the external drive is C:\\External, measured with the same rules, and the free space is checked first (three times the file)",
      '"C:\\\\External"' in src and "freeb.QuadPart < total * 3" in disk)
jit = src[src.index("static int test_jit"):src.index("/* ====", src.index("static int test_jit"))]
check("the host files are read only in a session that has MADEIRA_HOST_STATUS (an earlier session's files are not this session's)",
      "host_enabled()" in src[src.index("static void host_read_info"):src.index("static int host_wait_seq")] and src.count("host_enabled()") >= 2
      and 'GetEnvironmentVariableA("MADEIRA_HOST_STATUS"' in src)
check("the JIT pool test allocates nothing: no VirtualAlloc, no mapping, no executable memory; it reads the environment and the host files",
      not re.search(r"VirtualAlloc|VirtualProtect|MapViewOfFile|CreateFileMapping|HeapAlloc|malloc\(", jit) and "WINE_IOS_JIT_SIZE" in jit and "host_read_live()" in jit)
check("the registry is only read: no RegSetValue, RegCreateKey, RegDeleteKey, RegDeleteValue",
      not re.search(r"Reg(SetValue|SetKeyValue|CreateKey|DeleteKey|DeleteValue|DeleteTree)", src))
check("the program writes only to the log, its own disk-test files and the report file: no CopyFile, MoveFile, SetFileAttributes",
      not re.search(r"CopyFile|MoveFile|SetFileAttributes|SHFileOperation|WinExec|ShellExecute|CreateProcess", src))
check("the network test sends a HEAD request for / to the stores' public hosts and reads nothing else (no login, no cookie, no credential)",
      'L"HEAD"' in src and 'L"/"' in src and not re.search(r"WinHttpAddRequestHeaders|Authorization|password|token", src, re.I))
hosts = re.findall(r'"([a-z0-9.-]+\.(?:com|net))"', src[src.index("net_services[] ="):src.index("static const char *winhttp_error")])
check("... for Steam, Epic, GOG, Battle.net and EA", all(any(x in h for h in hosts) for x in ("steampowered", "epicgames", "gog.com", "battle.net", "ea.com")), hosts)
check("the program closes at the window's close button, Escape or the Close button; a test running then is told to stop (g_abort) and given 8 s",
      "InterlockedExchange(&g_abort, 1)" in src and "WaitForSingleObject(g_worker, 8000)" in src and "VK_ESCAPE" in src)
check("the window is plain: an edit control with a fixed-pitch font (nothing to load), and it works without a window (log only)",
      '"EDIT"' in src and "FIXED_PITCH" in src and "g_headless" in src)
check("core.h has no Windows header and no operating system call (it is built and run on the Mac)",
      not re.search(r"#include\s*<(windows|winsock|unistd|sys/)", core) and "#include <stdio.h>" in core)
for f in (SYS / "core.h", SYS / "core_test.c", SYS / "systest.c", Path(__file__)):
    head = f.read_text()[:500]
    check(f.name + " has the BCD licence header", "SPDX-License-Identifier: GPL-3.0-only" in head and "LICENSE-BCD.md" in head)

# ---------------------------------------------------------------- 4. the project
gi = (R / ".gitignore").read_text()
check(".gitignore lets the one tracked 32-bit program through, after the farm's rule", gi.index("app/Madeira/i386-windows/*") < gi.index("!app/Madeira/i386-windows/bcd-systest-x86.exe")
      and "build/systests/" in gi)
wf = (R / ".github/workflows/build-ipa.yml").read_text()
check("the workflow runs this check, builds the programs after the i386 farm, and checks the host status",
      "tests/host/check-systests.py" in wf and "tools/build-systests.sh" in wf and wf.index("Build i386 farm (WoW64)") < wf.index("tools/build-systests.sh")
      and "tests/host/check-host-status.py" in wf)
bs = (R / "tools/build-systests.sh").read_text()
check("the build script keeps the tracked programs when a build fails (a warning, exit 0) and checks the PE headers",
      "keeping the tracked program" in bs and bs.rstrip().endswith("exit 0") and "imports outside the allowed set" in bs)

shutil.rmtree(tmp, ignore_errors=True)
sys.exit(0 if ok else 1)
