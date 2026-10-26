#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""wine_process_exit_code() and the early-VA accessors (WineProcessBridge.m, JITAllocator.c).

Two small additions the app's Swift side can read without a thread-local or a mutable C global:

  1. wine_process_exit_code(): wine_ios_exit_code is _Thread_local, so it was printed on the Wine thread and
     lost. The boot thread now copies it to a plain global (release store) before the session's end work sets
     g_wine_running = 0, and the accessor reads it (acquire load). A session ended off the boot thread
     (wine_session_abandon, wine_session_dock_game_ended) publishes the status it knows the same way.
  2. madeira_early_pool_placeholder() and madeira_early_pool_intruder(): the values madeira_early_va_claim()
     wrote before main, as functions (Swift 6 strict concurrency cannot read a C global var).

The accessor bodies are compiled on the host against stand-in globals; both files are syntax-checked with
the iPhoneOS SDK when it is installed (WineProcessBridge.m and JITAllocator.c as the app compiles them).
Nothing here runs unless a caller asks, so a session behaves as before.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + detail) if detail and not cond else ""))
    if not cond:
        ok = False


bridge = (APP / "WineProcessBridge.m").read_text()
bridge_h = (APP / "WineProcessBridge.h").read_text()
jit = (APP / "JITAllocator.c").read_text()
jit_h = (APP / "JITAllocator.h").read_text()

# 1. the exit code
check("WineProcessBridge.h declares wine_process_exit_code()", "int wine_process_exit_code(void);" in bridge_h)
check("a plain global holds the copy, not thread-local", re.search(r"^static int g_wine_exit_code = 0;", bridge, re.M))
boot = bridge.index("__atomic_store_n(&g_wine_exit_code, (int)wine_ios_exit_code")
end_call = bridge.index("wine_session_end();", boot)
check("the boot thread publishes it (release) before the session's end work", boot < end_call
      and "__ATOMIC_RELEASE" in bridge[boot:boot + 160])
check("  and after the longjmp / normal return of __wine_main",
      boot > bridge.index("[WineProc] Wine exited with code %d (caught by longjmp)"))
check("the accessor is an acquire load", re.search(
    r"int wine_process_exit_code\(void\) \{\s*return __atomic_load_n\(&g_wine_exit_code, __ATOMIC_ACQUIRE\);\s*\}", bridge))
ab = bridge.index("void wine_session_abandon(void)")
ab_end = bridge.index("\n}\n", ab)
check("a session abandoned off the boot thread publishes the status it knows",
      "__atomic_store_n(&g_wine_exit_code, (int)code, __ATOMIC_RELEASE)" in bridge[ab:ab_end]
      and bridge[ab:ab_end].index("g_wine_exit_code") < bridge[ab:ab_end].index("wine_session_end();"))
dk = bridge.index("int wine_session_dock_game_ended(int32_t status)")
dk_end = bridge.index("\n}\n", dk)
check("a Dock game's end publishes its status before the end work",
      "__atomic_store_n(&g_wine_exit_code, (int)status, __ATOMIC_RELEASE)" in bridge[dk:dk_end]
      and bridge[dk:dk_end].index("g_wine_exit_code") < bridge[dk:dk_end].index("wine_session_end();"))

# 2. the early VA accessors, compiled against stand-in globals
m = re.search(r"void madeira_early_pool_placeholder\(.*?\n}\n\nvoid madeira_early_pool_intruder\(.*?\n}\n", jit, re.S)
check("JITAllocator.c defines both accessors", bool(m))
check("JITAllocator.h declares both",
      "void madeira_early_pool_placeholder(unsigned long *base, unsigned long *size);" in jit_h
      and "void madeira_early_pool_intruder(unsigned long *base, unsigned long *size, unsigned *tag);" in jit_h)
if m:
    tmp = Path(tempfile.mkdtemp(prefix="early-va-"))
    try:
        (tmp / "t.c").write_text(
            "#include <stdio.h>\n"
            "unsigned long madeira_early_pool_base = 0x180000000ul, madeira_early_pool_size = 0x10000000ul;\n"
            "unsigned long madeira_early_intruder_base = 0x1f0000000ul, madeira_early_intruder_size = 0x4000ul;\n"
            "unsigned madeira_early_intruder_tag = 7, madeira_early_intruder_prot = 3;\n"
            + m.group(0) +
            "int main(void){ unsigned long b=0,s=0; unsigned t=0;\n"
            "  madeira_early_pool_placeholder(&b,&s); if (b!=0x180000000ul||s!=0x10000000ul) return 1;\n"
            "  madeira_early_pool_intruder(&b,&s,&t); if (b!=0x1f0000000ul||s!=0x4000ul||t!=7) return 2;\n"
            "  madeira_early_pool_placeholder(NULL,&s); madeira_early_pool_placeholder(&b,NULL);\n"
            "  madeira_early_pool_intruder(NULL,NULL,NULL); madeira_early_pool_intruder(&b,NULL,&t); puts(\"ok\"); return 0; }\n")
        p = subprocess.run(["clang", "-Wall", "-Werror", str(tmp / "t.c"), "-o", str(tmp / "t")], capture_output=True, text=True)
        check("the accessors build on the host", p.returncode == 0, p.stderr[-400:])
        if p.returncode == 0:
            r = subprocess.run([str(tmp / "t")], capture_output=True, text=True)
            check("  they return what the globals hold, and take NULL for any output", r.returncode == 0, "rc=%d" % r.returncode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

# 3. both files compile against the iPhoneOS SDK (when installed)
sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True)
if sdk.returncode == 0 and sdk.stdout.strip():
    base = ["xcrun", "-sdk", "iphoneos", "clang", "-fsyntax-only", "-arch", "arm64", "-isysroot", sdk.stdout.strip(),
            "-miphoneos-version-min=17.0", "-I", str(APP)]
    for src, extra in (("WineProcessBridge.m", ["-fobjc-arc", "-x", "objective-c"]), ("JITAllocator.c", [])):
        p = subprocess.run(base + extra + [str(APP / src)], capture_output=True, text=True)
        check("%s compiles against the iPhoneOS SDK" % src, p.returncode == 0, p.stderr[-600:])
else:
    print("note iPhoneOS SDK not installed: the syntax checks are skipped")

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
