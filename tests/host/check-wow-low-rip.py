#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""A 32-bit program's branch to a low address faults in the guest (madeira-bcd, build 623; upstream Madeira 726686e).

FEX refuses a block below 64 KB and its dispatcher branches to 0; the host fault (pc 0, lr in the JIT pool) was dispatched
natively, the unwind stalled and the program ended c0000005 (36 BCD logs: MDK 2 HD, Atari 50, Sleeping Dogs, RE6, HL2...).
segv_handler now moves pc to the dispatcher's call for a WoW64 thread only, so FEX raises the access violation to the 32-bit
program. This checks the source: the block sits at the end of segv_handler, right before setup_exception, inside WINE_IOS;
its condition is the narrow one (switch, pc < 64 KB equal to the fault address, a WoW64 TEB, lr in the pool or the low pool);
MADEIRA_WOW_LOW_RIP_GUEST=0 turns it off; the auto-tune rule and its fixture name it; CI runs this check.
"""
from pathlib import Path
import sys

R = Path(__file__).resolve().parents[2]
src = (R / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
failures = []


def check(cond, what):
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond:
        failures.append(what)


start = src.index('static void segv_handler( int signal, siginfo_t *siginfo, void *sigcontext )')
end = src.index('\n}\n', start)
body = src[start:end]
i = body.find('[wow-low-rip] guest branch to %p')
check(i > 0, 'segv_handler has the [wow-low-rip] block')
tail = body[i:]
check(tail.index('PC_sig(context) = lp_lr - 4;') < tail.index('#endif') < tail.index('setup_exception( context, &rec );'),
      'it moves pc to the dispatcher call, inside WINE_IOS, right before setup_exception')
check('if (low_rip_guest && lp_pc < 0x10000 && (uintptr_t)siginfo->si_addr == lp_pc &&\n'
      '            NtCurrentTeb()->WowTebOffset && lp_lr >= 4 &&\n'
      '            ((lp_rx && lp_lr >= lp_rx && lp_lr < lp_rx + lp_sz) || ios_jit_low_contains( lp_lr )))' in body,
      'only a WoW64 thread, pc below 64 KB equal to the fault address, lr in the JIT pool')
check('const char *e = getenv( "MADEIRA_WOW_LOW_RIP_GUEST" );' in body and "low_rip_guest = !(e && e[0] == '0' && !e[1]);" in body,
      'MADEIRA_WOW_LOW_RIP_GUEST=0 turns it off (on otherwise)')
check('if (low_rip_logged++ < 16)' in body, 'the log line is capped at 16')
rules = (R / 'build/tools/autotune_rules.py').read_text()
check('"id": "wow64-low-rip-native-dispatch",' in rules and '"fixedIn": 623,' in rules.split('"id": "wow64-low-rip-native-dispatch",')[1][:200]
      and 's("[wow-low-rip]")' in rules, 'auto-tune knows the old crash as fixed in build 623, and not once [wow-low-rip] shows')
check((R / 'tests/fixtures/autotune/mdk2-hd-low-rip-2026-10-26.expect').is_file(), 'the MDK 2 HD fixture proves the rule')
wf = (R / '.github/workflows/build-ipa.yml').read_text()
check('python3 tests/host/check-wow-low-rip.py' in wf, 'CI runs this check')
if failures:
    print('FAILED: wow-low-rip')
    sys.exit(1)
print('PASS: a 32-bit branch to a low address faults in the guest (WoW64 only, switchable)')
