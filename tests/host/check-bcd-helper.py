#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""BCD's start helper (bcd-helper/, round 604): the file reader, the window rules and the end-of-game logic of core.h, run with the host's
clang and the sanitizers against a fake system; the tracked bcd-helper-x64.exe (an x86-64 GUI program with plain imports, no memory or
injection API anywhere in its source); and, when llvm-mingw is here, the rebuild compared byte for byte with the tracked program.
tests/host/check-game-setup.py also feeds core.h's reader the file the Swift side writes.
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
HELPER = R / "bcd-helper"
EXE = R / "app/Madeira/arm64ec-windows/bcd-helper-x64.exe"
HEADER = ["// SPDX-License-Identifier: GPL-3.0-only",
          "// Copyright 2026 thebcd69 (BCD)",
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md."]
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or not detail else "\n     " + str(detail)))
    ok &= bool(cond)


for f in ("core.h", "core_test.c", "file_test.c", "helper.c"):
    check(f"bcd-helper/{f}: BCD's licence header, exactly", (HELPER / f).read_text().split("\n")[:3] == HEADER)

clang = shutil.which("clang") or shutil.which("cc")
if not clang:
    check("a C compiler is here", False)
else:
    with tempfile.TemporaryDirectory(prefix="bcd-helper-") as tmp:
        t = Path(tmp)
        r = subprocess.run([clang, "-std=c11", "-Wall", "-Wextra", "-Werror", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
                            "-I" + str(HELPER), "-o", str(t / "core_test"), str(HELPER / "core_test.c")], capture_output=True, text=True)
        check("core.h compiles for the host with -Wall -Wextra -Werror and the sanitizers", r.returncode == 0, r.stderr[-2000:])
        if r.returncode == 0:
            r = subprocess.run([str(t / "core_test")], capture_output=True, text=True, timeout=120)
            print("\n".join("     " + l for l in r.stdout.strip().split("\n") if l.startswith("FAIL") or "checks," in l))
            check("the file reader, the window rules and the end-of-game logic hold", r.returncode == 0, (r.stdout + r.stderr)[-1500:])
            check("the helper's rule table is bounded (16 rules, 256 tracked windows)", "HR_MAX_RULES 16" in (HELPER / "core.h").read_text() and "HR_MAX_TRACK 256" in (HELPER / "core.h").read_text())

src = (HELPER / "helper.c").read_text()
check("the helper's source: no memory, hook, thread, debug, loader or process-start API (it only looks, raises, minimises and closes one program)",
      not re.search(r"WriteProcessMemory|ReadProcessMemory|CreateRemoteThread|VirtualAllocEx|SetWindowsHookEx|DebugActiveProcess|NtSuspend|SuspendThread|LoadLibrary|CreateProcess|ShellExecute|WinExec", src))
check("it opens a process only for its path (query) or to close the second program", set(re.findall(r"OpenProcess\((\w+)", src)) == {"PROCESS_QUERY_LIMITED_INFORMATION", "PROCESS_TERMINATE"}
      and src.count("TerminateProcess(") == 1)
check("the build script exists and ignores nothing it should keep", (R / "tools/build-bcd-helper.sh").exists() and "build/bcd-helper/" in (R / ".gitignore").read_text())

# The tracked program.
if not EXE.exists():
    check("bcd-helper-x64.exe is tracked in the ARM64EC farm", False)
else:
    data = EXE.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    check("it is a PE file for x86-64 (like the other BCD programs of the farm)", data[pe:pe + 4] == b"PE\0\0" and struct.unpack_from("<H", data, pe + 4)[0] == 0x8664)
    opt = pe + 24
    check("a 64-bit GUI program (it opens no window, and needs no console)", struct.unpack_from("<H", data, opt)[0] == 0x20B and struct.unpack_from("<H", data, opt + 68)[0] == 2)
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    secs = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
    sections = [struct.unpack_from("<8sIIII", data, secs + 40 * i) for i in range(nsec)]

    def rva2off(rva):
        for name, vsize, vaddr, rsize, roff in sections:
            if vaddr <= rva < vaddr + max(vsize, rsize):
                return roff + rva - vaddr
        raise AssertionError("rva")

    imp = struct.unpack_from("<I", data, opt + 112 + 8)[0]
    names = []
    o = rva2off(imp)
    while True:
        f = struct.unpack_from("<IIIII", data, o)
        if f[3] == 0:
            break
        n = rva2off(f[3])
        names.append(data[n:data.index(b"\0", n)].decode().lower())
        o += 20
    check("it imports only kernel32, user32 and the C runtime's api-ms-win-crt-*", all(n in ("kernel32.dll", "user32.dll") or n.startswith("api-ms-win-crt-") for n in names), names)
    farm = R / "app/Madeira/arm64ec-windows"
    have = {f.name.lower() for f in farm.iterdir()} if farm.exists() else set()
    check("every library it imports is in the ARM64EC farm", all(n.startswith("api-ms-win-") or n in have for n in names), [n for n in names if n not in have and not n.startswith("api-ms-win-")])
    check("its name holds 'helper' (the session-end check does not count such a program as the game's)", "helper" in EXE.name)
    check("it is small (a few dozen KB: no framework)", len(data) < 128 * 1024, len(data))
    # Rebuild and compare, when llvm-mingw is here.
    mingw = os.environ.get("MINGW") or next((str(p) for p in (R / "toolchains").glob("llvm-mingw-*/bin")), "") if (R / "toolchains").exists() else os.environ.get("MINGW", "")
    if mingw and (Path(mingw) / "x86_64-w64-mingw32-clang").exists():
        with tempfile.TemporaryDirectory(prefix="bcd-helper-build-") as tmp:
            env = dict(os.environ, MINGW=mingw, SHIP_DIR=tmp)
            r = subprocess.run(["bash", str(R / "tools/build-bcd-helper.sh")], cwd=R, env=env, capture_output=True, text=True, timeout=600)
            built = Path(tmp) / EXE.name
            check("the build is reproducible: rebuilding gives the tracked program byte for byte", built.exists() and built.read_bytes() == data, r.stdout[-600:] + r.stderr[-600:])
    else:
        print("note: llvm-mingw is not here; the byte-for-byte rebuild is left to the build machine")

workflow = (R / ".github/workflows/build-ipa.yml").read_text()
check("CI runs this check", "python3 tests/host/check-bcd-helper.py" in workflow)
print("PASS: BCD start helper" if ok else "FAIL: BCD start helper")
sys.exit(0 if ok else 1)
