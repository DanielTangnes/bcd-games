/* A scalar guest store that crosses the end of an anonymous alias, emulated page by page.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 * Copyright 2026 thebcd69 (BCD)
 * BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
 *
 * WHY THIS EXISTS
 * ---------------
 * Slay the Spire 2 (1WF6J7, D1A9QX, KRFN07; build 622, one iPad17,4 each): CoreCLR compiles Godot.Constructors..cctor, a
 * method of more than 128 KB, into RWX memory it commits one chunk at a time. Each chunk is its own anonymous alias (a
 * 16 KB page physically r-x, written through an RW view at another address). The JIT writes the 32-bit displacement of
 * `mov rcx,[rbp-0x430]` (48 8b 8d d0 fb ff ff) with an unaligned 4-byte store that starts two bytes before the end of
 * one chunk (offset 0x3ffe): `d0 fb` belong to this page, `ff ff` to the next chunk, which has an alias of its own. The store
 * emulator of signal_arm64_ios.c (the scalar STR/STUR/STLUR/STR-register branches) wrote the whole value at the first page's
 * RW address: the two high bytes went to whatever follows that RW view, and the next chunk kept its first two bytes
 * (00 00), so FEX translated `mov rcx,[rbp+0xfbd0]` instead. The log shows both ends of it: the next RW page starts
 * "ff ff fa 3f" where a stub of the runtime reads "ff 25 fa 3f" ([guest-bytes] ml631 #2 of 1WF6J7), and the exception is the
 * read of rbp+0xfbd0 (0x706df6b760) that ended the process as System.AccessViolationException in Godot.Constructors..cctor().
 *
 * The Q-pair (STP Q) and the SIMD/FP and pair branches already take each 16 KB page on its own (ios_store_split.h,
 * ml1276, ml1283); the scalar general-purpose stores did not.
 *
 * WHAT IT DOES
 * ------------
 *   ios_gpr_store_decode    which scalar GPR stores this handles, their width and base writeback
 *   ios_gpr_store_straddle  when the store's bytes cross a 16 KB boundary AND the first alias run does not hold all of them,
 *                           cut them at the boundary and write each part where the lookup puts it (ios_store_split.h).
 * A store that stays inside one page, or whose alias run holds all of it (the pages are contiguous in the RW view as well),
 * is NOT touched: the old branches write it exactly as before. A store whose parts cannot be placed writes nothing and
 * returns 0, so the old branches run as they always did.
 *
 * No Wine type, no Mach type: tests/host/check-gpr-store-straddle.py compiles this header with fake lookups.
 */
#ifndef IOS_GPR_STORE_STRADDLE_H
#define IOS_GPR_STORE_STRADDLE_H

#include "ios_store_split.h"

typedef struct
{
    unsigned bytes;   /* 1, 2, 4 or 8 */
    int      rt;      /* the stored register (31 = XZR) */
    int      rn;      /* the base register (31 = SP) */
    int      wb;      /* 0 none, 1 post-index, 3 pre-index */
    int64_t  imm;     /* the index offset (wb != 0) */
} ios_gpr_store;

/* 1 for STRB/STRH/STR Wt|Xt with an unsigned offset, STUR / STR post- and pre-index (imm9), STR (register offset) and
 * STLURB/STLURH/STLUR (the store-release form FEX uses for guest stores under TSO). 0 for everything else. */
static inline int ios_gpr_store_decode( uint32_t insn, ios_gpr_store *s )
{
    s->bytes = 1u << (insn >> 30);
    s->rt = insn & 0x1f;
    s->rn = (insn >> 5) & 0x1f;
    s->wb = 0;
    s->imm = 0;
    if ((insn & 0x3fc00000) == 0x39000000)                       /* unsigned offset */
        return 1;
    if ((insn & 0x3fe00000) == 0x38000000 && ((insn >> 10) & 3) != 2)   /* unscaled, post-index, pre-index */
    {
        int64_t imm9 = (int64_t)((insn >> 12) & 0x1ff);
        const int mode = (insn >> 10) & 3;
        if (imm9 & 0x100) imm9 -= 0x200;
        if (mode == 1 || mode == 3) { s->wb = mode; s->imm = imm9; }
        return 1;
    }
    if ((insn & 0x3fe00c00) == 0x38200800)                       /* register offset */
        return 1;
    if ((insn & 0x3fe00c00) == 0x19000000)                       /* STLUR{B,H,} unscaled */
        return 1;
    return 0;
}

/* The bytes [ea, ea + bytes) leave the 16 KB page that holds ea. */
static inline int ios_gpr_store_crosses( uintptr_t ea, unsigned bytes )
{
    return bytes > 1 && (ea & (IOS_STORE_SPLIT_PAGE - 1)) + bytes > IOS_STORE_SPLIT_PAGE;
}

/* The base register after the store (wb != 0): pre-index stores at base + imm and keeps it, post-index stores at base and adds. */
static inline uint64_t ios_gpr_store_new_base( const ios_gpr_store *s, uint64_t ea )
{
    return s->wb == 1 ? ea + (uint64_t)s->imm : ea;
}

/* Returns 1 when the store was written page by page (the caller applies the base writeback and counts the instruction as
 * emulated), 0 when it is not a scalar store of the kind above, does not cross a page boundary, is held whole by the alias run
 * (`alias_whole`: the lookup of its last byte is the first byte's plus bytes - 1), or cannot be placed: in every such case
 * nothing has been written. `value` is the register's value; the first `bytes` bytes of it (little endian) are stored. */
static inline int ios_gpr_store_straddle( uint32_t insn, uintptr_t ea, uint64_t value, int alias_whole,
                                          ios_store_resolve_fn resolve, ios_store_direct_fn direct_write, void *ctx,
                                          ios_gpr_store *dec, int *nparts )
{
    ios_store_part parts[2];
    int n;

    *nparts = 0;
    if (!ios_gpr_store_decode( insn, dec )) return 0;
    if (!ios_gpr_store_crosses( ea, dec->bytes ) || alias_whole) return 0;
    n = ios_store_split_plan( ea, dec->bytes, resolve, ctx, parts );
    if (!n) return 0;
    if (!ios_store_split_commit( parts, n, &value, direct_write, ctx )) return 0;
    *nparts = n;
    return 1;
}

#endif /* IOS_GPR_STORE_STRADDLE_H */
