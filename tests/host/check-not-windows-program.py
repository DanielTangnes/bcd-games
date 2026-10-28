#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
"""Add a game: a file without the "MZ" header is refused with words that name the likely cause (thebcd69/bcd-games#17).

LibraryModel.inspect refused such a file with "This file is not a Windows program." only. It now asks
notWindowsProgramText for the words: an empty file, a ZIP / RAR / 7-Zip archive or a web page saved under a .exe name,
a file too short to be a program, or a damaged or partly downloaded one. The file is refused exactly as before; this
check compiles the real function from app/Madeira/Library.swift and runs it on those cases.
"""
import re, shutil, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
ok = True


def check(name, cond, detail=''):
    global ok
    print(('ok   ' if cond else 'FAIL ') + name)
    if not cond:
        ok = False
        if detail:
            print('     ' + str(detail)[:1500])


lib = (root / 'app/Madeira/Library.swift').read_text()
check('inspect refuses a file without "MZ" with the helper\'s words, as before otherwise',
      'guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { throw LibraryError.message(Self.notWindowsProgramText(dos)) }' in lib)
start = lib.index('    static func notWindowsProgramText(_ head: Data) -> String {')
end = lib.index('\n    }\n', start) + len('\n    }\n')
fn = lib[start:end]
swiftc = shutil.which('swiftc') or (shutil.which('xcrun') and 'xcrun')
if not swiftc:
    print('SKIP the run: no Swift compiler')
else:
    harness = 'import Foundation\nenum M {\n' + fn + '''}
func t(_ bytes: [UInt8]) -> String { M.notWindowsProgramText(Data(bytes)) }
var pad = [UInt8](repeating: 0x20, count: 80)
print("empty=" + t([]))
print("zip=" + t([0x50, 0x4b, 0x03, 0x04] + pad))
print("rar=" + t(Array("Rar!".utf8) + pad))
print("7z=" + t([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c] + pad))
print("html=" + t(Array("<!DOCTYPE html><html><head>".utf8) + pad))
print("short=" + t([0x00, 0x01, 0x02]))
print("other=" + t([0x7f, 0x45, 0x4c, 0x46] + pad))
'''
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / 'main.swift'
        src.write_text(harness)
        exe = Path(tmp) / 'm'
        cmd = ([swiftc] if swiftc != 'xcrun' else ['xcrun', 'swiftc']) + [str(src), '-o', str(exe)]
        b = subprocess.run(cmd, capture_output=True, text=True)
        check('the helper compiles on the host', b.returncode == 0, b.stderr[-2000:])
        if b.returncode == 0:
            out = dict(l.split('=', 1) for l in subprocess.run([str(exe)], capture_output=True, text=True).stdout.splitlines())
            check('an empty file says it is empty and not finished', '(0 bytes)' in out['empty'] and 'did not finish' in out['empty'], out['empty'])
            check('a ZIP, RAR or 7-Zip archive is named as one', 'a ZIP archive' in out['zip'] and 'a RAR archive' in out['rar']
                  and 'a 7-Zip archive' in out['7z'], out)
            check('a web page saved as .exe is named as one', 'a web page' in out['html'], out['html'])
            check('a very short file says so with its size', '(3 bytes)' in out['short'], out['short'])
            check('anything else: damaged or partly downloaded', 'damaged or only partly downloaded' in out['other'], out['other'])
            check('every answer still says it is not a Windows program (or empty / too short)',
                  all(('not a Windows program' in v) or ('empty' in v) or ('too short' in v) for v in out.values()), out)
wf = (root / '.github/workflows/build-ipa.yml').read_text()
check('CI runs this check', 'python3 tests/host/check-not-windows-program.py' in wf)
print('PASS: not a Windows program' if ok else 'FAILED: not a Windows program')
sys.exit(0 if ok else 1)
