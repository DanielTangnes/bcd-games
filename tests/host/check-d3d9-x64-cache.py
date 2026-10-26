#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The 64-bit Direct3D 9 default (BCDGraphicsDefaults.swift, round 602) remembers each game's answer, so only the first start after an
install or an update pays for the folder scan (up to its 4 s limit). The remembered answer is keyed by the folder and a signature of the
folder's and the started program's modification time and size; the game's own word and the master switch are still read first.
The cache functions are compiled with swiftc and run against a temporary folder."""
import os, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path
R = Path(__file__).resolve().parents[2]
src = (R / 'app/Madeira/BCDGraphicsDefaults.swift').read_text()
ok = True
def check(name, cond):
    global ok
    print(('ok   ' if cond else 'FAIL ') + name)
    ok = ok and cond
body = src[src.find('static func applyD3D9X64'):src.find('// MARK: the remembered answers')]
check('the own word and the master switch come before the cache', body.find('MadeiraConfig.flag(d3d9X64AutoKey)') < body.find('cachedDecision(')
      and body.find('if let own {') < body.find('cachedDecision('))
check('the library gate comes before the cache', body.find('known.contains("D3D11")') < body.find('cachedDecision('))
check('a scan result is remembered', 'remember(root, signature: signature, dxmt: dxmt, why: why)' in body)
check('a remembered answer is logged as remembered', body.count('remembered)') == 2)
m = src[src.find('// MARK: the remembered answers'):src.find('/// The folder tree of the game an entry starts')]
swiftc = shutil.which('swiftc')
if not swiftc:
    check('swiftc available', False)
else:
    with tempfile.TemporaryDirectory() as t:
        prog = Path(t) / 'main.swift'
        prog.write_text('import Foundation\nenum C {\n' + m + '\n}\n' + r'''
let d = URL(fileURLWithPath: CommandLine.arguments[1]); let exe = d.appendingPathComponent("game.exe")
UserDefaults.standard.removeObject(forKey: C.cacheKey)
let s1 = C.folderSignature(d, target: exe)
print("miss", C.cachedDecision(d, signature: s1) == nil)
C.remember(d, signature: s1, dxmt: true, why: "a|b")
let hit = C.cachedDecision(d, signature: s1)
print("hit", hit?.dxmt == true && hit?.why == "a/b")
try! Data(repeating: 1, count: 4096).write(to: exe)
let s2 = C.folderSignature(d, target: exe)
print("changed", s2 != s1 && C.cachedDecision(d, signature: s2) == nil)
for i in 0..<(C.cacheLimit + 5) { C.remember(URL(fileURLWithPath: "/x/\(i)"), signature: "s", dxmt: false, why: "w") }
print("bounded", (UserDefaults.standard.dictionary(forKey: C.cacheKey) ?? [:]).count <= C.cacheLimit)
UserDefaults.standard.removeObject(forKey: C.cacheKey)
''')
        exe = Path(t) / 'c'
        b = subprocess.run([swiftc, '-o', str(exe), str(prog)], capture_output=True, text=True)
        check('the cache functions compile', b.returncode == 0)
        if b.returncode == 0:
            g = Path(t) / 'game'; g.mkdir(); (g / 'game.exe').write_bytes(b'MZ' + b'\0' * 100)
            out = subprocess.run([str(exe), str(g)], capture_output=True, text=True).stdout.split('\n')
            for k in ('miss', 'hit', 'changed', 'bounded'):
                check('cache: ' + k, f'{k} true' in out)
print('PASS: d3d9-x64 cache' if ok else 'FAILED: d3d9-x64 cache')
sys.exit(0 if ok else 1)
