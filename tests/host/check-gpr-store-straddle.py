#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""A scalar guest store that crosses the end of an anonymous alias is stored page by page (build 623); no Wine runs.

Slay the Spire 2 (1WF6J7, D1A9QX, KRFN07; build 622, iPad17,4): CoreCLR writes the displacement of `mov rcx,[rbp-0x430]`
(48 8b 8d d0 fb ff ff) with a 4-byte store that starts two bytes before the end of a 16 KB chunk of its RWX code heap. Every
chunk is its own alias (physically r-x, written through an RW view somewhere else), so the store emulator of
signal_arm64_ios.c wrote all four bytes at the first chunk's RW address: `ff ff` ended up in whatever follows that RW view (a stub
page of the runtime, "ff 25 fa 3f" became "ff ff fa 3f") and the next chunk kept 00 00, which FEX translated as
`mov rcx,[rbp+0xfbd0]`; the read of 0x706df6b760 ended the game ("System.AccessViolationException ... at
Godot.Constructors..cctor()"). The STP Q, SIMD/FP and pair branches already stored each 16 KB page on its own
(ios_store_split.h); the scalar general-purpose branches did not.

Compiled runs: the production header build/ntdll-unix/ios_gpr_store_straddle.h against a simulated guest address space whose
alias RW views are NOT contiguous (separate buffers with guard bytes, which is the whole point):
  - the decoder takes STRB/STRH/STR W/X (unsigned offset), STUR / STR post-/pre-index (imm9), STR (register offset) and
    STLURB/STLURH/STLUR with the right width and base writeback, and takes nothing else (loads, STP, SIMD stores, STTR,
    atomics, exclusives, store-release);
  - the Slay the Spire 2 geometry (4 bytes, two before the end of the page, the next page with its own alias): each byte in
    its page's own view, the guard bytes behind the first view untouched;
  - every width (2, 4, 8) at every straddling start: the next page aliased, a plain writable page (one direct write), a read-only
    or unmapped page (nothing written at all, not even the aliased part: the old path then runs as before);
  - a store inside a page, one that ends exactly on the boundary, and one whose alias run already holds all of it
    (`alias_whole`: contiguous RW views, the old path is right) are not touched;
  - the base writeback value of the pre- and post-index forms.
And textually, in signal_arm64_ios.c: the header is included once; the new block sits before the first emulation branch, is
for `!in_jit` only (the JIT pool is contiguous and unchanged), runs only when the alias run does not hold the whole store,
sets `emulated` only when the split succeeded and logs a refusal; the first branch of the chain is skipped once the store is
done (`if (emulated)`), and the old scalar branches remain as they were.
Needs python3 and a C compiler.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
header = root / 'build/ntdll-unix/ios_gpr_store_straddle.h'
ok = True


def check(what, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what)
    ok = ok and bool(cond)


harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include "ios_gpr_store_straddle.h"

static int failures;
#define EXPECT(c, msg) do { if (!(c)) { printf("FAIL %s\n", msg); failures++; } } while (0)

/* Simulated guest pages of 16 KB at G. Each aliased page has its own RW view: view[p] points into a separate buffer with
 * 64 guard bytes (0xEE) on both sides, so a write that runs past the end of one view hits a guard, not the next page. */
#define G 0x7198a7c000ull
enum { ALIAS, WRITABLE, READONLY, UNMAPPED };
static int kind[4];
static uint8_t view_mem[4][0x4000 + 128];
static uint8_t direct_mem[4][0x4000];
static int direct_calls;
static int page_of(uintptr_t a) { return (int)((a - G) >> 14); }
static uint8_t *view(int p) { return &view_mem[p][64]; }

static uintptr_t resolve(void *ctx, uintptr_t guest, unsigned len, int *direct)
{
    int p = page_of(guest);
    (void)ctx; (void)len;
    if (kind[p] == ALIAS) { *direct = 0; return (uintptr_t)(view(p) + ((guest - G) & 0x3fff)); }
    *direct = 1;
    return guest;
}
static int dwrite(void *ctx, uintptr_t guest, const void *s, unsigned len)
{
    int p = page_of(guest);
    (void)ctx;
    direct_calls++;
    if (kind[p] != WRITABLE) return 0;
    memcpy(&direct_mem[p][(guest - G) & 0x3fff], s, len);
    return 1;
}
static void reset(int k1)
{
    memset(view_mem, 0xEE, sizeof view_mem);
    memset(direct_mem, 0, sizeof direct_mem);
    kind[0] = ALIAS; kind[1] = k1; kind[2] = ALIAS; kind[3] = ALIAS;
    direct_calls = 0;
}
static int guards_intact(int p)
{
    int i;
    for (i = 0; i < 64; i++) if (view_mem[p][i] != 0xEE || view_mem[p][64 + 0x4000 + i] != 0xEE) return 0;
    return 1;
}

static int dec(uint32_t insn, unsigned bytes, int wb, int64_t imm)
{
    ios_gpr_store s;
    return ios_gpr_store_decode(insn, &s) && s.bytes == bytes && s.wb == wb && s.imm == imm;
}
static int nodec(uint32_t insn) { ios_gpr_store s; return !ios_gpr_store_decode(insn, &s); }

int main(void)
{
    ios_gpr_store d;
    int np;
    uint32_t sz;

    /* ---- the decoder: stores it takes ---- */
    EXPECT(dec(0x39000000, 1, 0, 0), "STRB w0,[x0] (unsigned offset)");
    EXPECT(dec(0x7900002a, 2, 0, 0), "STRH w10,[x1]");
    EXPECT(dec(0xb9000fe1, 4, 0, 0), "STR w1,[sp,#12]");
    EXPECT(dec(0xf9001ae8, 8, 0, 0), "STR x8,[x23,#48]");
    EXPECT(dec(0xf8000001, 8, 0, 0), "STUR x1,[x0] (the write-barrier store of D1A9QX, unscaled)");
    EXPECT(dec(0xb8003401, 4, 1, 0x3), "STR w1,[x0],#3 (post-index, imm9 = 3)");
    EXPECT(dec(0xb81f0c01, 4, 3, -16), "STR w1,[x0,#-16]! (pre-index)");
    EXPECT(dec(0xf81f8ee6, 8, 3, -8), "STR x6,[x23,#-8]! (pre-index, the shape of ntdll's prologues)");
    EXPECT(dec(0x38000401, 1, 1, 0), "STRB w1,[x0],#0 (post-index)");
    EXPECT(dec(0xb8206801, 4, 0, 0), "STR w1,[x0,x0] (register offset)");
    EXPECT(dec(0x78200800 | 1, 2, 0, 0), "STRH w1,[x0,x0] (register offset)");
    EXPECT(dec(0x19000100, 1, 0, 0), "STLURB w0,[x8] (FCPrimal's store)");
    EXPECT(dec(0x19006103, 1, 0, 0), "STLURB w3,[x8,#6]");
    EXPECT(dec(0x59000100, 2, 0, 0), "STLURH w0,[x8]");
    EXPECT(dec(0x99000100, 4, 0, 0), "STLUR w0,[x8]");
    EXPECT(dec(0xd9000100, 8, 0, 0), "STLUR x0,[x8]");

    /* ---- the decoder: everything else is left to the old branches ---- */
    EXPECT(nodec(0xb9400000), "LDR w0,[x0] (a load)");
    EXPECT(nodec(0xf9400100), "LDR x0,[x8]");
    EXPECT(nodec(0xa9000000), "STP x0,x0,[x0]");
    EXPECT(nodec(0x29000000), "STP w0,w0,[x0]");
    EXPECT(nodec(0xac814570), "STP q16,q17,[x11],#32");
    EXPECT(nodec(0xbd000000), "STR s0,[x0] (SIMD)");
    EXPECT(nodec(0x3d800000), "STR q0,[x0] (SIMD)");
    EXPECT(nodec(0xbc029260), "STUR s0,[x19,#41] (SIMD)");
    EXPECT(nodec(0xb8000800), "STTR w0,[x0] (unprivileged)");
    EXPECT(nodec(0xb8f50106), "LDADDAL w21,w6,[x8]");
    EXPECT(nodec(0xf8f980d9), "SWPAL x25,x25,[x6]");
    EXPECT(nodec(0x88007c00), "STXR w0,w0,[x0]");
    EXPECT(nodec(0x889ffc00), "STLR w0,[x0]");
    EXPECT(nodec(0xc89ffc00), "STLR x0,[x0]");
    EXPECT(nodec(0x88e07c00), "CASAL");
    EXPECT(nodec(0xd503201f), "NOP");
    EXPECT(nodec(0xd94000c0), "LDUR x0,[x6]");

    /* ---- crossing ---- */
    EXPECT(!ios_gpr_store_crosses(G + 0x100, 4), "inside a page");
    EXPECT(!ios_gpr_store_crosses(G + 0x3ffc, 4), "ends exactly on the boundary");
    EXPECT(ios_gpr_store_crosses(G + 0x3ffe, 4), "starts two bytes before the end");
    EXPECT(ios_gpr_store_crosses(G + 0x3fff, 2), "2 bytes, 1 + 1");
    EXPECT(!ios_gpr_store_crosses(G + 0x3fff, 1), "1 byte never crosses");

    /* ---- the Slay the Spire 2 store: STLUR w, 4 bytes at offset 0x3ffe, the next page has its own alias ---- */
    {
        const uint64_t value = 0xfffffbd0ull;   /* the displacement: d0 fb ff ff */
        reset(ALIAS);
        EXPECT(ios_gpr_store_straddle(0x99000100, G + 0x3ffe, value, 0, resolve, dwrite, NULL, &d, &np) == 1 && np == 2, "split into two");
        EXPECT(view(0)[0x3ffe] == 0xd0 && view(0)[0x3fff] == 0xfb, "d0 fb at the end of the first view");
        EXPECT(view(1)[0] == 0xff && view(1)[1] == 0xff, "ff ff at the start of the next page's own view");
        EXPECT(guards_intact(0) && guards_intact(1), "nothing written behind the first view (the old bug)");
        EXPECT(direct_calls == 0, "no direct write");
        EXPECT(view(0)[0x3ffd] == 0xEE && view(1)[2] == 0xEE, "no other byte written");
    }

    /* ---- every width at every straddling start, three kinds of next page ---- */
    for (sz = 2; sz <= 8; sz <<= 1)
    {
        uint32_t insn = sz == 2 ? 0x59000100 : sz == 4 ? 0x99000100 : 0xd9000100;
        unsigned off;
        for (off = 1; off < sz; off++)
        {
            uint64_t v = 0x1122334455667788ull;
            uint8_t b[8];
            unsigned k;
            memcpy(b, &v, 8);

            reset(ALIAS);
            EXPECT(ios_gpr_store_straddle(insn, G + 0x4000 - off, v, 0, resolve, dwrite, NULL, &d, &np) == 1 && np == 2, "aliased next page");
            for (k = 0; k < off; k++) EXPECT(view(0)[0x4000 - off + k] == b[k], "first part byte");
            for (k = off; k < sz; k++) EXPECT(view(1)[k - off] == b[k], "second part byte");
            EXPECT(guards_intact(0) && guards_intact(1), "guards (aliased)");

            reset(WRITABLE);
            EXPECT(ios_gpr_store_straddle(insn, G + 0x4000 - off, v, 0, resolve, dwrite, NULL, &d, &np) == 1 && np == 2 && direct_calls == 1, "plain writable next page: one direct write");
            for (k = 0; k < off; k++) EXPECT(view(0)[0x4000 - off + k] == b[k], "first part byte (direct)");
            for (k = off; k < sz; k++) EXPECT(direct_mem[1][k - off] == b[k], "second part byte (direct)");
            EXPECT(guards_intact(0), "guards (direct)");

            reset(READONLY);
            EXPECT(ios_gpr_store_straddle(insn, G + 0x4000 - off, v, 0, resolve, dwrite, NULL, &d, &np) == 0, "read-only next page: refused");
            { int clean = 1; for (k = 0; k < 0x4000; k++) if (view(0)[k] != 0xEE) clean = 0; EXPECT(clean, "read-only next page: nothing written, not even the aliased part"); }
            reset(UNMAPPED);
            EXPECT(ios_gpr_store_straddle(insn, G + 0x4000 - off, v, 0, resolve, dwrite, NULL, &d, &np) == 0, "unmapped next page: refused");
            { int clean = 1; for (k = 0; k < 0x4000; k++) if (view(0)[k] != 0xEE) clean = 0; EXPECT(clean, "unmapped next page: nothing written"); }
        }
    }

    /* ---- not touched ---- */
    reset(ALIAS);
    EXPECT(ios_gpr_store_straddle(0x99000100, G + 0x100, 0x11223344, 0, resolve, dwrite, NULL, &d, &np) == 0 && view(0)[0x100] == 0xEE,
           "a store inside a page is not taken");
    EXPECT(ios_gpr_store_straddle(0x99000100, G + 0x3ffc, 0x11223344, 0, resolve, dwrite, NULL, &d, &np) == 0 && view(0)[0x3ffc] == 0xEE,
           "a store that ends on the boundary is not taken");
    EXPECT(ios_gpr_store_straddle(0x99000100, G + 0x3ffe, 0x11223344, 1, resolve, dwrite, NULL, &d, &np) == 0 && view(0)[0x3ffe] == 0xEE,
           "a store the first alias run holds whole (contiguous views) is not taken: the old path writes it");
    EXPECT(ios_gpr_store_straddle(0xb9400000, G + 0x3ffe, 0x11223344, 0, resolve, dwrite, NULL, &d, &np) == 0 && view(0)[0x3ffe] == 0xEE,
           "a load is not taken");
    EXPECT(ios_gpr_store_straddle(0x39000000, G + 0x3fff, 0x11, 0, resolve, dwrite, NULL, &d, &np) == 0, "one byte is not taken");

    /* ---- the base writeback ---- */
    {
        ios_gpr_store s;
        ios_gpr_store_decode(0xb8003401, &s);          /* post-index +3 */
        EXPECT(ios_gpr_store_new_base(&s, 0x1000) == 0x1003, "post-index: the store is at the base, the base moves on");
        ios_gpr_store_decode(0xb81f0c01, &s);          /* pre-index -16 */
        EXPECT(ios_gpr_store_new_base(&s, 0x1000) == 0x1000, "pre-index: the effective address is the new base");
    }

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all checks passed\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'gpr_straddle.c'
    c.write_text(harness)
    exe = Path(tmp) / 'gpr_straddle'
    cc = subprocess.run(['cc', '-O1', '-Wall', '-I', str(header.parent), '-o', str(exe), str(c)],
                        capture_output=True, text=True)
    check('the production header compiles on the host', cc.returncode == 0)
    if cc.returncode:
        print(cc.stderr)
    else:
        if cc.stderr.strip():
            print(cc.stderr)
        run = subprocess.run([str(exe)], capture_output=True, text=True)
        for line in run.stdout.splitlines():
            print('     ' + line)
        check('the compiled checks pass', run.returncode == 0)

# ---------------------------------------------------------------- the integration, textually
inc = '#include "ios_gpr_store_straddle.h"'
check('the header is included once, after ios_store_split.h and before the Mach exception thread',
      src.count(inc) == 1 and src.index('#include "ios_store_split.h"') < src.index(inc)
      < src.index('static void *ios_mach_exception_thread( void *arg )'))
blk_at = src.index('/* build 623 (Slay the Spire 2, 1WF6J7 / D1A9QX / KRFN07): a scalar store')
chain_at = src.index('if (emulated)\n                    {\n                        /* build 623: stored page by page above */\n                    }\n'
                     '                    else if (have_neon && (insn & 0xFE400000) == 0xAC000000)')
blk = src[blk_at:chain_at]
check('the block sits after the instruction is read and before the first emulation branch',
      src.rindex('uint32_t insn; ios_fault_read_insn(', 0, blk_at) > 0 and blk_at < chain_at)
check('only an anonymous alias: the JIT pool case is not touched', 'if (!in_jit)' in blk)
check('only a store that crosses a 16 KB boundary', 'ios_gpr_store_crosses( (uintptr_t)fault_addr, gs.bytes )' in blk)
check('only when the alias run does not hold the whole store',
      'ios_jit_anon_alias_lookup( (uintptr_t)fault_addr + gs.bytes - 1 ) == rw_addr + gs.bytes - 1' in blk and 'if (!gwhole &&' in blk)
check('the value is the register, XZR as 0', 'IOS_STORE_SRC(gs.rt)' in blk)
check('the production resolver and the mach_vm_write direct writer are used',
      'ios_store_split_resolve_anon' in blk and 'ios_store_split_direct_write' in blk)
check('the base writeback follows the split, SP aware',
      'ios_gpr_store_new_base( &gs, (uint64_t)fault_addr )' in blk and 'state.__sp = nb' in blk and 'state.__x[gs.rn] = nb' in blk)
good = blk[blk.index('ios_gpr_store_straddle('):blk.index('else if (!gwhole && gpr_split_fail_n < 4)')]
check('emulated is set only after a successful split', good.count('emulated = 1;') == 1)
refuse = blk[blk.index('else if (!gwhole && gpr_split_fail_n < 4)'):]
check('a refusal is logged (capped) and does not set emulated', 'emulated' not in refuse and 'gpr_split_fail_n < 4' in blk)
check('the success line is capped', 'gpr_split_n < 8' in blk)
for what, text in (
    ('STR 64-bit, unsigned offset', '*(uint64_t *)rw_addr = IOS_STORE_SRC(rt);'),
    ('STR 32-bit, unsigned offset', '*(uint32_t *)rw_addr = (uint32_t)IOS_STORE_SRC(rt);'),
    ('STRB', '*(uint8_t *)rw_addr = (uint8_t)IOS_STORE_SRC(rt);'),
    ('STRH', '*(uint16_t *)rw_addr = (uint16_t)IOS_STORE_SRC(rt);'),
    ('STLUR', 'memcpy((void *)rw_addr, &v, 1u << (insn >> 30));'),
):
    check('the old branch is unchanged: ' + what, text in src[chain_at:])
check('the Q-pair branch is unchanged', 'const int stp_whole = rw_end && rw_end == (uintptr_t)rw_addr + 31;' in src)

print('PASS: gpr store straddle' if ok else 'FAIL: gpr store straddle')
raise SystemExit(0 if ok else 1)
