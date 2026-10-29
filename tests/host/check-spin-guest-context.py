#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""[spin] ml677: the guest code window and the guest stack added in round 623; no Wine runs.

Forza Horizon 4 (Send Logs D9NHGJ, RVXHV6, 58VNDB; build 622, iPad17,1; same place in all three, 941 s in D9NHGJ): the game's
only thread spins at ForzaHorizon4.exe+0x304d8a0 for as long as the player waits, and the [spin] snapshot (D9NHGJ L12159-L12190)
names the loop with 32 guest bytes - `movzx eax, [rbp+0x2b0]; test al, al; je -11` - but not the function around it. The
region marked spin-ctx in build/ntdll-unix/signal_arm64_ios.c adds, on that failure path only, 256 guest code bytes from rip-192,
the guest registers the register allocation keeps in host registers, and 128 guest stack words from RSP.

1. The region compiled on the host against a fake memory (mach_vm_read_overwrite replaced by a bounded reader): the readable
   case prints 8 code lines of 32 bytes starting at rip-192 and 32 stack lines of 4 words; an unreadable code window and an
   unreadable or implausible RSP print that they were not readable and nothing else; a rip below 192 reads nothing.
2. Wiring: the region sits inside `if (exact)` of the spin snapshot, after the 32-byte dump, and reads guest memory only through
   mach_vm_read_overwrite (no pointer is dereferenced, no PE export is called).
"""
from pathlib import Path
import os, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
path = root / "build/ntdll-unix/signal_arm64_ios.c"
src = path.read_text()
ok = True


def check(what, cond, extra=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or not extra else "  -- " + extra))
    ok &= bool(cond)


b = src.find("/* spin-ctx:begin */")
e = src.find("/* spin-ctx:end */")
check("the spin-ctx region is there once", b > 0 and e > b and src.count("/* spin-ctx:begin */") == 1 and src.count("/* spin-ctx:end */") == 1)
if b < 0 or e < b:
    sys.exit(1)
region = src[b + len("/* spin-ctx:begin */"):e]

harness = r"""
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
#define KERN_SUCCESS 0
#define KERN_INVALID_ADDRESS 1
#define mach_task_self() 0
#define mach_vm_read_overwrite(task, addr, size, out, outsz) fake_read( (addr), (size), (void *)(out), (outsz) )

/* fake guest memory: [MEM_BASE, MEM_BASE + MEM_SIZE) is readable, the byte at address a holds (a * 7 + 3) & 0xff */
#define MEM_BASE 0x10000ull
#define MEM_SIZE 0x4000ull
static int reads, last_ok;
static int fake_read( uint64_t addr, uint64_t size, void *out, mach_vm_size_t *outsz )
{
    uint64_t i;
    reads++;
    if (addr < MEM_BASE || addr + size > MEM_BASE + MEM_SIZE) { last_ok = 0; *outsz = 0; return KERN_INVALID_ADDRESS; }
    for (i = 0; i < size; i++) ((uint8_t *)out)[i] = (uint8_t)((addr + i) * 7 + 3);
    *outsz = size;
    last_ok = 1;
    return KERN_SUCCESS;
}

struct fake_state { uint64_t __x[29]; uint64_t __fp; };

static void run( uint64_t exact, uint64_t rsp )
{
    struct fake_state st;
    memset( &st, 0, sizeof(st) );
    st.__x[23] = rsp;
    st.__fp = 0x7037eef010ull;
    st.__x[8] = 0x1111; st.__x[20] = 0x2000;
""" + region + r"""
}

int main( void )
{
    /* readable: rip-192 .. rip+64 and 1024 bytes of stack */
    fputs( "CASE readable\n", stderr );
    run( MEM_BASE + 0x1000, MEM_BASE + 0x2000 );
    /* code window below the readable memory */
    fputs( "CASE code-unreadable\n", stderr );
    run( MEM_BASE + 100, MEM_BASE + 0x2000 );
    /* rsp at the end of the readable memory: 1024 bytes do not fit */
    fputs( "CASE stack-unreadable\n", stderr );
    run( MEM_BASE + 0x1000, MEM_BASE + MEM_SIZE - 64 );
    /* rsp implausible */
    fputs( "CASE stack-implausible\n", stderr );
    run( MEM_BASE + 0x1000, 0x1234 );
    /* rip below 192: nothing is read for the code window */
    fputs( "CASE rip-small\n", stderr );
    reads = 0;
    run( 100, MEM_BASE + 0x2000 );
    printf( "reads=%d\n", reads );
    return 0;
}
"""
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "ctx.c"
    c.write_text(harness)
    exe = Path(t) / "ctx"
    r = subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Wno-unused-parameter", "-fsanitize=address,undefined", str(c), "-o", str(exe)],
                       capture_output=True, text=True)
    check("the spin-ctx region compiles on the host with no warning", r.returncode == 0 and "warning" not in r.stderr, r.stderr[-1200:])
    if r.returncode == 0:
        p = subprocess.run([str(exe)], capture_output=True, text=True, env={**os.environ, "ASAN_OPTIONS": "symbolize=0"})
        check("it runs clean under ASan/UBSan", p.returncode == 0, (p.stdout + p.stderr)[-1500:])
        runs, cur_run = [], None
        for ln in p.stderr.splitlines():
            if ln.startswith("CASE "):
                cur_run = []
                runs.append(cur_run)
            elif cur_run is not None:
                cur_run.append(ln)
        check("five runs reported", len(runs) == 5, "got %d" % len(runs))
        if len(runs) == 5:
            rd, cu, su, si, rs = runs
            code = [x for x in rd if x.startswith("[spin]   guest code @")]
            stack = [x for x in rd if x.startswith("[spin]   guest stack x23+")]
            check("readable: 8 code lines of 32 bytes, the first at rip-192", len(code) == 8 and
                  code[0].startswith("[spin]   guest code @0x%x: " % (0x10000 + 0x1000 - 192)) and
                  all(len(x.split(": ", 1)[1].split()) == 32 for x in code))
            check("readable: the second code line is 32 bytes on", code[1].startswith("[spin]   guest code @0x%x: " % (0x10000 + 0x1000 - 192 + 32)))
            check("readable: the code bytes are the fake memory's bytes", code[0].split(": ", 1)[1].split()[0] == "%02x" % (((0x10000 + 0x1000 - 192) * 7 + 3) & 0xff))
            check("readable: 32 stack lines of 4 words, offsets 0x000..0x3e0", len(stack) == 32 and stack[0].startswith("[spin]   guest stack x23+0x000: ")
                  and stack[-1].startswith("[spin]   guest stack x23+0x3e0: ") and all(len(x.split(": ", 1)[1].split()) == 4 for x in stack))
            regs = [x for x in rd if x.startswith("[spin]   guest regs")]
            check("readable: one registers line, x23, x29 (the fp) and x20 as set", len(regs) == 1 and "x23=0x12000" in regs[0]
                  and "x29=0x7037eef010" in regs[0] and "x20=0x2000" in regs[0] and "x8=0x1111" in regs[0])
            check("code window unreadable: said so, nothing else for the code", any("guest code @0x%x: UNREADABLE" % (0x10000 + 100 - 192) in x for x in cu)
                  and not any(x.startswith("[spin]   guest code @0x") and "UNREADABLE" not in x for x in cu))
            check("stack unreadable: said so, no stack line", any("guest stack x23=0x" in x and "not readable" in x for x in su)
                  and not any(x.startswith("[spin]   guest stack x23+") for x in su))
            check("stack implausible: said so, no stack line", any("guest stack x23=0x1234: not readable" in x for x in si)
                  and not any(x.startswith("[spin]   guest stack x23+") for x in si))
            check("rip below 192: the code window is reported unreadable without a read", any("UNREADABLE" in x for x in rs))
        check("the reads of the last case: the code window is not read, only the stack is", "reads=1" in p.stdout, p.stdout[-300:])

# ------------------------------------------------------------------ 2. wiring
exact_blk = src[src.index("{   /* the guest bytes at the real RIP name the loop */"):e]
check("the region is inside `if (exact)` after the 32-byte dump", exact_blk.index("guest bytes @0x%llx") < exact_blk.index("spin-ctx:begin")
      and src[:src.index("{   /* the guest bytes at the real RIP name the loop */")].rstrip().endswith("if (exact)"))
check("guest memory is read only through mach_vm_read_overwrite (no dereference of a guest pointer, no PE export)",
      "mach_vm_read_overwrite" in region and "*(uint64_t *)" not in region and "ios_native_rip_from_hostpc" not in region
      and "ios_guest_module_for" not in region)
check("the sizes are bounded (256 code bytes, 128 stack words)", "uint8_t cw[256]" in region and "uint64_t sw[128]" in region)
check("the earlier 32-byte dump and the block header dump are unchanged", "[spin]   guest bytes @0x%llx: %s\\n" in src
      and "[spin]     block hdr: %016llx %016llx %016llx %016llx %016llx %016llx\\n" in src)

sys.exit(0 if ok else 1)
