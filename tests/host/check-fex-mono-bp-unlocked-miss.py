#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""tools/patch-fex-ios-mono-bp-unlocked-miss.py: MonoBackpatcherWrite's alias-miss store outside CodeInvalidationMutex (opt-in); no Wine runs.

The bug (round 623, Send Logs 9DEZ8A Kindergarten, 997BBV Mycopunk, XYPY9J Skate Story, build 622; five more of builds 614-622): the helper
holds CodeInvalidationMutex (write) across a store that, on an alias-table miss, goes to a read+execute page and raises an access violation
inside this native function. The exception leaves the function without running the lock's destructor, the mutex stays write-owned by the
thread and the thread's next request waits for itself ("[fexlock] STUCK write-wait ... owner tid == waiting tid").

1. The patch on the pinned Core.cpp: applies once, is idempotent, refuses a changed anchor and a partial overlay; the default (env unset)
   does what the unpatched function does.
2. Behaviour, compiled on the host (the real function text from Core.cpp, the lock/alias/store collaborators replaced by stubs; a real
   SIGSEGV on a read-only page stands for the access violation and siglongjmp for the abandoned native frame):
   - the unpatched function (and the patched one with the env unset) leaves the mutex LOCKED after a faulting store: the bug;
   - the patched function with MADEIRA_MONO_BP_UNLOCKED_MISS=1 leaves it UNLOCKED, a hit is still stored under the lock, a miss that does not
     fault is stored without the lock, InvalidateGuestCodeRange runs after the store in both, a size other than 4 or 8 still dies.
3. Wiring: tools/build-xtajit64.sh applies the patch after the fork-overlay branch (so it runs for the current pin too), Core.cpp is in its
   checkout list, and the key is in the settings catalog.

FEX_ROOT=<dir> selects the FEX tree (default: FEX/ of the repository; the check says so and passes when neither has a Core.cpp).
"""
from pathlib import Path
import importlib.util, os, re, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
fex = Path(os.environ.get("FEX_ROOT") or root / "FEX")
core_path = fex / "FEXCore/Source/Interface/Core/Core.cpp"
ok = True


def check(what, cond, extra=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or not extra else "  -- " + extra))
    ok &= bool(cond)


spec = importlib.util.spec_from_file_location("monobp", root / "tools/patch-fex-ios-mono-bp-unlocked-miss.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# ------------------------------------------------------------------ 3. wiring (needs no FEX tree)
build = (root / "tools/build-xtajit64.sh").read_text()
cat = (root / "build/tools/gen-config-catalog.py").read_text()
call = 'python3 "$R/tools/patch-fex-ios-mono-bp-unlocked-miss.py" "$R/FEX/FEXCore/Source/Interface/Core/Core.cpp"'
gate = build.index('if grep -q "ec-ret-direct-v1 madeira-bcd"')
after_pin = build.index("\nfi\n", gate)
build_step = build.index("\nbuild\n", after_pin)
check("tools/build-xtajit64.sh runs the patch once, after the pin branch and before the build step",
      build.count(call) == 1 and after_pin < build.index(call) < build_step)
checkout = build[build_step:].split("git -C FEX checkout --", 1)[1].split("\n", 1)[0]
check("Core.cpp is in the checkout list that undoes the overlays after the build", "FEXCore/Source/Interface/Core/Core.cpp" in checkout.split())
check("the key is in the settings catalog with this patch as its source",
      '"env.MADEIRA_MONO_BP_UNLOCKED_MISS"' in cat and "tools/patch-fex-ios-mono-bp-unlocked-miss.py" in cat)

if not core_path.exists():
    print("skip the rest: no FEX tree (%s); set FEX_ROOT or check out the submodule" % core_path)
    sys.exit(0 if ok else 1)

core = core_path.read_text()
# ------------------------------------------------------------------ 1. the patch
patched = mod.patch(core)
check("the patch changes the pinned file once", patched != core and patched.count(mod.MARKER) >= 1 and "IosMonoMissUnlocked()" in patched)
check("it is idempotent", mod.patch(patched) == patched)
for what, src in (("a changed anchor", core.replace(mod.HEAD, mod.HEAD.replace("Frame->Thread", "Frame->Thread2"))),
                  ("a partial overlay", patched.replace(mod.BLOCK, mod.MARKER))):
    try:
        mod.patch(src)
        check("refuses " + what, False)
    except ValueError:
        check("refuses " + what, True)
check("the default path is the original text after the new block (nothing below the block changed)",
      patched.split(mod.BLOCK, 1)[1].startswith("  {\n    auto lk = GuardSignalDeferringSection(CTX->CodeInvalidationMutex, Thread);"))
check("the new block is compiled only for iOS and takes the same lock type as the original",
      mod.BLOCK.startswith("#ifdef FEX_IOS_HOST") and mod.BLOCK.rstrip().endswith("#endif")
      and "GuardSignalDeferringSection(CTX->CodeInvalidationMutex, Thread)" in mod.BLOCK)


# ------------------------------------------------------------------ 2b. the real compiler on the real file (when the FEX build tree is there)
ccj = fex / "build-arm64ec/compile_commands.json"
if ccj.exists():
    import json, shlex
    entry = [e for e in json.loads(ccj.read_text()) if e["file"].endswith("Interface/Core/Core.cpp")]
    if entry:
        args = shlex.split(entry[0]["command"])
        keep, i = [], 0
        while i < len(args):
            a = args[i]
            if a in ("-o", "-c"):
                i += 2
                continue
            if a.endswith("Core.cpp"):
                i += 1
                continue
            if a == "-MD":
                i += 1
                continue
            if a in ("-MT", "-MF"):
                i += 2
                continue
            keep.append(a)
            i += 1
        with tempfile.TemporaryDirectory() as t:
            f = Path(t) / "Core_patched.cpp"
            f.write_text(patched)
            near = str(core_path.parent)
            cmd = keep + ["-I" + near, "-I" + str(core_path.parent.parent), "-fsyntax-only", "-w", str(f)]
            r = subprocess.run(cmd, capture_output=True, text=True, cwd=entry[0]["directory"])
            check("the patched Core.cpp compiles with the real FEX flags (-fsyntax-only, FEX_IOS_HOST, arm64ec)", r.returncode == 0, r.stderr[-1500:])
else:
    print("skip the real-compiler check: %s is not there" % ccj)


# ------------------------------------------------------------------ 2. behaviour
def func_text(text):
    start = text.find("#ifdef FEX_IOS_HOST\n/* " + mod.MARKER.split()[0])
    if start < 0 or start > text.index("void ContextImpl::MonoBackpatcherWrite("):
        start = text.index("void ContextImpl::MonoBackpatcherWrite(")
    return text[start:text.index("void ContextImpl::ConfigureAOTGen(")]


HARNESS = r"""
#include <atomic>
#include <csetjmp>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <unistd.h>
#define FEX_IOS_HOST 1

static int die_called, miss_logs, invalidated;
static sigjmp_buf env_jmp;
#define ERROR_AND_DIE_FMT(...) do { die_called++; siglongjmp(env_jmp, 2); } while (0)
namespace LogMan::Msg { template <class... T> void EFmt(const char*, T&&...) { miss_logs++; } }

struct Mutex { bool locked = false; bool locked_at_store = false; };
struct Guard {
  Mutex& m;
  explicit Guard(Mutex& mm) : m(mm) { m.locked = true; }
  ~Guard() { m.locked = false; }
};
template <class T> inline Guard GuardSignalDeferringSection(Mutex& m, T*) { return Guard(m); }

namespace FEXCore::Core { struct InternalThreadState; struct CpuStateFrame { InternalThreadState* Thread; }; }
namespace FEXCore::Context {
struct SyscallHandlerStub {
  void InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState*, uint64_t, uint64_t);
};
struct Context {};
struct ContextImpl : Context {
  Mutex CodeInvalidationMutex;
  SyscallHandlerStub* SyscallHandler;
  uint64_t GetGuestBase() { return 0; }
  static void MonoBackpatcherWrite(FEXCore::Core::CpuStateFrame* Frame, uint8_t Size, uint64_t Address, uint64_t Value);
};
}
namespace FEXCore::Core { struct InternalThreadState { FEXCore::Context::Context* CTX; }; }
using namespace FEXCore::Context;

static ContextImpl ctx;
static SyscallHandlerStub sys_stub;
static uint64_t hit_base, hit_size, hit_rw;
static bool locked_when_invalidated;
void FEXCore::Context::SyscallHandlerStub::InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState*, uint64_t, uint64_t) {
  invalidated++;
  locked_when_invalidated = ctx.CodeInvalidationMutex.locked;
}
extern "C" uint64_t IosMonoResolveRW(uint64_t a, uint64_t s) {
  if (hit_size && a >= hit_base && a + s <= hit_base + hit_size) return hit_rw + (a - hit_base);
  return 0;
}
extern "C" void ios_fex_mono_count_helper(int) {}

""" + "%FUNC%" + r"""

static void on_segv(int) { siglongjmp(env_jmp, 1); }

static int run_case(const char* name, uint8_t size, uint64_t addr, uint64_t value, bool expect_fault) {
  FEXCore::Core::InternalThreadState th;
  th.CTX = &ctx;
  FEXCore::Core::CpuStateFrame fr{&th};
  ctx.SyscallHandler = &sys_stub;
  ctx.CodeInvalidationMutex.locked = false;
  invalidated = 0; die_called = 0; miss_logs = 0; locked_when_invalidated = false;
  int how = sigsetjmp(env_jmp, 1);
  if (how == 0) {
    ContextImpl::MonoBackpatcherWrite(&fr, size, addr, value);
  }
  printf("%s fault=%d died=%d locked_after=%d invalidated=%d locked_at_invalidate=%d miss_logs=%d\n", name, how == 1, how == 2,
         ctx.CodeInvalidationMutex.locked, invalidated, locked_when_invalidated, miss_logs);
  (void)expect_fault;
  return 0;
}

int main() {
  struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = on_segv; sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, nullptr); sigaction(SIGBUS, &sa, nullptr);
  const long pg = sysconf(_SC_PAGESIZE);
  uint8_t* ro = (uint8_t*)mmap(nullptr, pg, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0);
  uint8_t* rw = (uint8_t*)mmap(nullptr, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  uint8_t* plain = (uint8_t*)mmap(nullptr, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  uint8_t* alias = (uint8_t*)mmap(nullptr, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  (void)rw;
  /* a hit: the guest range [ro, ro+pg) has a writable alias */
  hit_base = (uint64_t)ro; hit_size = pg; hit_rw = (uint64_t)alias;
  run_case("hit8", 8, (uint64_t)ro + 8, 0x1122334455667788ull, false);
  printf("hit8 stored=%llx\n", (unsigned long long)*(uint64_t*)(alias + 8));
  run_case("hit4", 4, (uint64_t)ro + 16, 0xdeadbeefull, false);
  printf("hit4 stored=%x\n", *(uint32_t*)(alias + 16));
  /* a miss whose direct store works */
  hit_size = 0;
  run_case("miss-ok8", 8, (uint64_t)plain + 8, 0xa1a2a3a4a5a6a7a8ull, false);
  printf("miss-ok8 stored=%llx\n", (unsigned long long)*(uint64_t*)(plain + 8));
  /* a miss whose direct store faults (read-only page): the access violation of the logs */
  run_case("miss-fault8", 8, (uint64_t)ro + 8, 1, true);
  run_case("miss-fault4", 4, (uint64_t)ro + 24, 1, true);
  /* a size other than 4 or 8 */
  run_case("size2", 2, (uint64_t)plain + 32, 1, false);
  return 0;
}
"""


def build_and_run(label, text, env_value):
    src = HARNESS.replace("%FUNC%", func_text(text))
    with tempfile.TemporaryDirectory() as t:
        c = Path(t) / "h.cpp"
        c.write_text(src)
        exe = Path(t) / "h"
        r = subprocess.run(["c++", "-std=c++20", "-O0", "-w", str(c), "-o", str(exe)], capture_output=True, text=True)
        check("%s compiles on the host" % label, r.returncode == 0, r.stderr[-1500:])
        if r.returncode:
            return None
        env = {k: v for k, v in os.environ.items() if k != "MADEIRA_MONO_BP_UNLOCKED_MISS"}
        if env_value is not None:
            env["MADEIRA_MONO_BP_UNLOCKED_MISS"] = env_value
        p = subprocess.run([str(exe)], capture_output=True, text=True, env=env)
        out = {}
        for ln in p.stdout.splitlines():
            name, rest = ln.split(" ", 1)
            out.setdefault(name, {}).update(dict(kv.split("=") for kv in rest.split()))
        check("%s runs" % label, p.returncode == 0 and "miss-fault8" in out, (p.stdout + p.stderr)[-800:])
        return out


orig = build_and_run("the unpatched function", core, None)
off = build_and_run("the patched function, env unset", patched, None)
on = build_and_run("the patched function, MADEIRA_MONO_BP_UNLOCKED_MISS=1", patched, "1")
other = build_and_run("the patched function, MADEIRA_MONO_BP_UNLOCKED_MISS=2", patched, "2")
if orig and off and on and other:
    for label, o in (("unpatched", orig), ("patched, env unset", off), ("patched, env=2", other)):
        check("%s: a faulting store leaves the mutex locked (the bug, kept as it was)" % label,
              o["miss-fault8"]["fault"] == "1" and o["miss-fault8"]["locked_after"] == "1" and o["miss-fault4"]["locked_after"] == "1")
    check("env=1: a faulting store leaves the mutex unlocked (8 and 4 bytes)",
          on["miss-fault8"]["fault"] == "1" and on["miss-fault8"]["locked_after"] == "0"
          and on["miss-fault4"]["fault"] == "1" and on["miss-fault4"]["locked_after"] == "0")
    check("env=1: no invalidation after the fault (the frame is gone), as in the original",
          on["miss-fault8"]["invalidated"] == "0" and orig["miss-fault8"]["invalidated"] == "0")
    for label, o in (("unpatched", orig), ("env unset", off), ("env=1", on), ("env=2", other)):
        check("%s: a hit is stored through the alias, then invalidated with the mutex released" % label,
              o["hit8"]["fault"] == "0" and o["hit8"]["invalidated"] == "1" and o["hit8"]["locked_after"] == "0"
              and o["hit8"]["locked_at_invalidate"] == "0" and o["hit4"]["fault"] == "0" and o["hit4"]["invalidated"] == "1")
        check("%s: a miss without a fault is stored and invalidated" % label,
              o["miss-ok8"]["fault"] == "0" and o["miss-ok8"]["invalidated"] == "1" and o["miss-ok8"]["locked_after"] == "0")
        check("%s: a size of 2 still dies" % label, o["size2"]["died"] == "1")
    check("env=1: a miss logs once; the default logs nothing", on["miss-ok8"]["miss_logs"] == "1" and orig["miss-ok8"]["miss_logs"] == "0"
          and off["miss-ok8"]["miss_logs"] == "0" and on["hit8"]["miss_logs"] == "0")
    check("every non-fault line of the default and of the original agree (nothing but the opt-in differs)",
          {k: v for k, v in orig.items()} == {k: v for k, v in off.items()} == {k: v for k, v in other.items()})

sys.exit(0 if ok else 1)
