#!/usr/bin/env python3
"""MonoBackpatcherWrite: an opt-in that keeps its direct store out of CodeInvalidationMutex.

FEXCore::Context::ContextImpl::MonoBackpatcherWrite (FEXCore/Source/Interface/Core/Core.cpp) takes CodeInvalidationMutex for
writing, resolves the writable alias of the guest address (IosMonoResolveRW) and stores through it. When the alias table has
no entry for the address (a miss), the store goes to the guest address itself, and the comment in the function expects it to
fault and be emulated "as before". The helper is native ARM64EC code, not JIT code, so the Mach handler does not emulate the
fault: it is delivered to the program as an access violation (c0000005 at libarm64ecfex.dll+0x16440 in build 622, the
`str x22, [x26]` of this function, with the page `COMMITTED READ EXEC`). The exception leaves the function without running
the unique_lock's destructor, so the mutex stays write-owned by that thread, and the next time the thread asks for it
(the next backpatch, or a code invalidation) it waits for itself for ever: "[fexlock] STUCK write-wait ... owner tid=<its
own tid>". Send Logs 9DEZ8A (Kindergarten), 997BBV (Mycopunk), XYPY9J (Skate Story), build 622, and five more of builds
614-622: the last access violation of the thread that later parks is this store (see the round 623 report of ajan61).

MADEIRA_MONO_BP_UNLOCKED_MISS=1 (read when the first backpatch runs): the alias lookup and a hit's store stay under the
mutex exactly as before; on a miss the mutex is released first and the direct store runs without it, so an access violation
raised by that store leaves nothing behind. Unset or anything else: the function as it was. The first 8 misses are logged
("[mono-bp] RW miss").

Apply to the temporary ARM64EC build copy, never update the pinned submodule (tools/build-xtajit64.sh).
"""
from pathlib import Path
import sys

MARKER = "mono-bp-unlocked-miss-v1 madeira-bcd"

HEAD = """void ContextImpl::MonoBackpatcherWrite(FEXCore::Core::CpuStateFrame* Frame, uint8_t Size, uint64_t Address, uint64_t Value) {
  auto Thread = Frame->Thread;
  auto CTX = static_cast<ContextImpl*>(Thread->CTX);
"""

HELPER = """#ifdef FEX_IOS_HOST
/* mono-bp-unlocked-miss-v1 madeira-bcd: MADEIRA_MONO_BP_UNLOCKED_MISS=1 opts in (read once). See MonoBackpatcherWrite. */
static bool IosMonoMissUnlocked() {
  /* A plain tri-state like the other switches of this module (no guarded static); two threads that race here read the same environment. */
  static int On = -1;
  if (On < 0) {
    const char* Env = getenv("MADEIRA_MONO_BP_UNLOCKED_MISS");
    On = (Env && Env[0] == '1' && !Env[1]) ? 1 : 0;
  }
  return On == 1;
}
#endif

"""

BLOCK = """#ifdef FEX_IOS_HOST
  if (IosMonoMissUnlocked() && (Size == 4 || Size == 8)) {
    /* mono-bp-unlocked-miss-v1 madeira-bcd: the store of an alias MISS runs without CodeInvalidationMutex. The direct store to a
     * read+execute page raises an access violation inside this native function; the exception leaves it without running the
     * lock's destructor and the thread then waits for the mutex it still owns ("[fexlock] STUCK write-wait", owner == waiter;
     * Kindergarten, Mycopunk, Skate Story, build 622). A hit is stored through the alias under the mutex as before. */
    uint64_t RW = 0;
    {
      auto lk = GuardSignalDeferringSection(CTX->CodeInvalidationMutex, Thread);
      RW = IosMonoResolveRW(Address, Size);
      ios_fex_mono_count_helper(RW ? 0 : 1);
      if (RW) {
        if (Size == 8) {
          *reinterpret_cast<uint64_t*>(RW) = Value;
        } else {
          *reinterpret_cast<uint32_t*>(RW) = Value;
        }
      }
    }
    if (!RW) {
      static std::atomic<int> MissLog {0};
      if (MissLog.fetch_add(1, std::memory_order_relaxed) < 8) {
        LogMan::Msg::EFmt("[mono-bp] RW miss: guest {:x} size {}: the direct store runs outside CodeInvalidationMutex "
                          "(MADEIRA_MONO_BP_UNLOCKED_MISS=1, mono-bp-unlocked-miss-v1)",
                          Address, Size);
      }
      const uint64_t Dest = Address + CTX->GetGuestBase();
      if (Size == 8) {
        *reinterpret_cast<uint64_t*>(Dest) = Value;
      } else {
        *reinterpret_cast<uint32_t*>(Dest) = Value;
      }
    }
    CTX->SyscallHandler->InvalidateGuestCodeRange(Thread, Address, Size);
    return;
  }
#endif
"""


def patch(source):
    after = HELPER + HEAD + BLOCK
    if MARKER in source:
        if source.count(after) != 1:
            raise ValueError("partial or changed MonoBackpatcherWrite overlay")
        return source
    if source.count(HEAD) != 1:
        raise ValueError("MonoBackpatcherWrite head changed")
    return source.replace(HEAD, after, 1)


if __name__ == "__main__":
    path = Path(sys.argv[1])
    source = path.read_text()
    try:
        result = patch(source)
    except ValueError as error:
        sys.exit("patch-fex-ios-mono-bp-unlocked-miss: " + str(error))
    if result != source:
        path.write_text(result)
    print("FEX ARM64EC: MonoBackpatcherWrite stores an alias miss outside CodeInvalidationMutex when MADEIRA_MONO_BP_UNLOCKED_MISS=1; default unchanged")
