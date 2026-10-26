#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The plain Windows desktop session mirrors every line of the guests' .log files (up to 800) so the Start menu tests' results reach the
session log; programs started from the Start menu get a new console and no BCD stderr (round 602, ajan43's finding). The two settings
live inside the host-status block, which runs only for the plain desktop session (BCDHostStatus.c: desktop, not Dock, explorer.exe), and
they never replace a value the player set (setenv's last argument 0)."""
import re, sys
from pathlib import Path
R = Path(__file__).resolve().parents[2]
src = (R / 'app/Madeira/WineProcessBridge.m').read_text()
ok = True
def check(name, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + name)
    ok = ok and cond
i = src.rfind('if (bcd_host_status_wanted(getenv("MADEIRA_DESKTOP"), getenv("MADEIRA_DOCK_SESSION"), getenv("MADEIRA_EXE"),')
check('the host-status block exists', i >= 0)
block = src[i:src.find('\n            }\n', i)]
check('the mirror is set to every line inside that block', 'setenv("MADEIRA_GUEST_LOG", "all", 0);' in block)
check('with an 800-line limit inside that block', 'setenv("MADEIRA_GUEST_LOG_LIMIT", "800", 0);' in block)
check('nowhere else, and never overwriting', len(re.findall(r'setenv\("MADEIRA_GUEST_LOG', src)) == 2
      and not re.search(r'setenv\("MADEIRA_GUEST_LOG[^)]*,\s*1\)', src))
hs = (R / 'app/Madeira/BCDHostStatus.c').read_text()
check('the block is the plain desktop only (not Dock, explorer.exe)', "if (dock_session && dock_session[0] == '1') return 0;" in hs
      and 'return base_is_explorer(exe);' in hs)
# 2026-10-25: the plain desktop session also defaults 64-bit Direct3D 9 to DXMT (the Start menu's 64-bit DirectX 9 test), never over a set value.
i2 = src.find('setenv("MADEIRA_D3D9_X64", "dxmt", 0);')
check('the desktop default for 64-bit D3D9 is DXMT, gated by the plain-desktop rule and before the link reads it',
      i2 > 0 and 'bcd_host_status_wanted(getenv("MADEIRA_DESKTOP"), getenv("MADEIRA_DOCK_SESSION"), getenv("MADEIRA_EXE"), NULL))' in src[i2-200:i2]
      and i2 < src.find('const char *d3d9X64 = getenv("MADEIRA_D3D9_X64");'))
i3 = src.find('setenv("MADEIRA_D3D8", "d3d9", 0);')
check('the desktop default for Direct3D 8 is d3d8to9, gated by the plain-desktop rule, before the routes are linked',
      i3 > 0 and 'getenv("MADEIRA_EXE"), NULL))' in src[i3-120:i3] and i3 < src.find('bcd_wow_routes_apply('))
print('PASS: desktop guest-log mirror' if ok else 'FAILED: desktop guest-log mirror')
sys.exit(0 if ok else 1)
