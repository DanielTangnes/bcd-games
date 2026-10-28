#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
"""NtMapViewOfSection: an explicit base inside a 32-bit program's WoW64 window (madeira-bcd, round 620).

A 32-bit program's explicit section base reaches BCD's NtMapViewOfSection window-biased (guest 0x50000000 is
<window base> + 0x50000000) with wow64's zero_bits 0xffffffff, and the "addr and zero_bits must match" test refused
every such base with STATUS_INVALID_PARAMETER_4 (c00000f2). DirectPlay's dplayx maps its static data at 0x50000000 and
retries without a base only on ERROR_INVALID_ADDRESS (487), so it gave up and read through NULL: Requiem: Avenging Angel
(EDZH2K, build 614, "[nt-fail] #2 NtMapViewOfSection status=c00000f2 ... hint=0x7950000000 zb=0xffffffff", then
"DPLAYX_ConstructData : unable to map static data into process memory space (87)"), Hotline Miami (15HRX1, build 580),
StarCraft through Battle.net (TS5WR4). The test now judges the guest address for a base in this process's own window.

This check compiles the real block out of build/ntdll-unix/virtual_ios.c with small stand-ins and runs it:
  - a base in the window with zero_bits 0xffffffff passes (it was refused);
  - the same numbers without a window, a base outside the window, a base of another process and a bad mask are
    refused exactly as before;
  - the small-zero_bits form (1..21) uses the same guest address.
Then, when a configured Wine tree is there (WINE_SRC), virtual_ios.c is compiled for iOS (syntax only).
"""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
ok = True


def check(name, cond, detail=''):
    global ok
    print(('ok   ' if cond else 'FAIL ') + name)
    if not cond:
        ok = False
        if detail:
            print('     ' + str(detail)[:2000])


src = (root / 'build/ntdll-unix/virtual_ios.c').read_text(errors='replace')
fn = src.index('static inline __attribute__((always_inline)) NTSTATUS ios_nt_impl_NtMapViewOfSection(')
body = src[fn:src.index('\n}\n', fn)]
start = body.index('    /* If both addr_ptr and zero_bits are passed, they have match */\n    {\n')
block = body[start:]
depth = 0
for i, ch in enumerate(block):
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            block = block[:i + 1]
            break
check('the parameter test sits in ios_nt_impl_NtMapViewOfSection and uses the guest address only for this process\'s window',
      'process == NtCurrentProcess() && ios_wow_in_window( *addr_ptr )' in block and 'check_addr -= ios_wow_base();' in block
      and '(check_addr >> (32 - zero_bits))' in block and '(check_addr & ~zero_bits)' in block, block)
check('the old tests on the raw address are gone from this function',
      '((UINT_PTR)*addr_ptr & ~zero_bits)' not in body and '((UINT_PTR)*addr_ptr >> (32 - zero_bits))' not in body)
check('the 22..31 zero_bits refusal before it is unchanged',
      'if (zero_bits > 21 && zero_bits < 32)\n        return STATUS_INVALID_PARAMETER_4;' in body)

harness = r'''
#include <stdio.h>
#include <stdint.h>
typedef uintptr_t UINT_PTR; typedef uintptr_t ULONG_PTR; typedef void *PVOID; typedef void *HANDLE; typedef unsigned int NTSTATUS;
#define STATUS_INVALID_PARAMETER_4 0xc00000f2u
#define NtCurrentProcess() ((HANDLE)~(UINT_PTR)0)
#define IOS_WOW_WINDOW_SIZE 0x100000000ull
static ULONG_PTR window_base;
static ULONG_PTR ios_wow_base(void) { return window_base; }
static int ios_wow_in_window( const void *addr )
{ return window_base && (ULONG_PTR)addr >= window_base && (ULONG_PTR)addr < window_base + IOS_WOW_WINDOW_SIZE; }
static NTSTATUS test( HANDLE process, PVOID *addr_ptr, ULONG_PTR zero_bits )
{
BLOCK
    return 0;
}
static int run( ULONG_PTR base, HANDLE process, ULONG_PTR addr, ULONG_PTR zero_bits )
{ void *a = (void *)addr; window_base = base; return test( process, &a, zero_bits ) == 0; }
int main(void)
{
    HANDLE self = NtCurrentProcess(), other = (HANDLE)(UINT_PTR)0x88;
    printf("in-window-mask=%d\n", run(0x7900000000ull, self, 0x7950000000ull, 0xffffffff));
    printf("in-window-null=%d\n", run(0x7900000000ull, self, 0, 0xffffffff));
    printf("no-window=%d\n", run(0, self, 0x7950000000ull, 0xffffffff));
    printf("outside-window=%d\n", run(0x7900000000ull, self, 0x7a50000000ull, 0xffffffff));
    printf("other-process=%d\n", run(0x7900000000ull, other, 0x7950000000ull, 0xffffffff));
    printf("in-window-small-bits-ok=%d\n", run(0x7900000000ull, self, 0x7900010000ull, 8));
    printf("in-window-small-bits-high=%d\n", run(0x7900000000ull, self, 0x7950000000ull, 8));
    printf("plain-low-mask=%d\n", run(0, self, 0x50000000ull, 0xffffffff));
    printf("plain-64bit-free=%d\n", run(0, self, 0x7950000000ull, 0));
    return 0;
}
'''.replace('BLOCK', block)
cc = shutil.which('cc') or shutil.which('clang')
if cc:
    with tempfile.TemporaryDirectory() as tmp:
        c = Path(tmp) / 'h.c'
        c.write_text(harness)
        exe = Path(tmp) / 'h'
        r = subprocess.run([cc, '-std=c11', '-Wall', '-Werror', '-o', str(exe), str(c)], capture_output=True, text=True)
        check('the block compiles on the host with stand-ins', r.returncode == 0, r.stderr)
        if r.returncode == 0:
            out = dict(l.split('=') for l in subprocess.run([str(exe)], capture_output=True, text=True).stdout.split())
            check('a base inside this process\'s window with wow64\'s 0xffffffff passes (it was refused: c00000f2)', out['in-window-mask'] == '1', out)
            check('no base passes as before', out['in-window-null'] == '1', out)
            check('the same address without a window is refused as before', out['no-window'] == '0', out)
            check('a base outside the window is refused as before', out['outside-window'] == '0', out)
            check('a base for another process is judged as before (its window is not ours)', out['other-process'] == '0', out)
            check('the small-zero_bits form judges the guest address too', out['in-window-small-bits-ok'] == '1'
                  and out['in-window-small-bits-high'] == '0', out)
            check('a plain guest-range address and a 64-bit call without zero_bits are untouched',
                  out['plain-low-mask'] == '1' and out['plain-64bit-free'] == '1', out)
else:
    print('skip the host harness: no C compiler')

wine = Path(os.environ.get('WINE_SRC', root / 'wine'))
config = wine / 'build-macos/include/config.h'
if shutil.which('xcrun') and config.exists():
    sdk = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    build = root / 'build/ntdll-unix'
    flags = ['-fsyntax-only', '-arch', 'arm64', '-isysroot', sdk, '-miphoneos-version-min=17.0', '-O2', '-fPIC',
             '-fno-strict-aliasing', '-Wno-implicit-function-declaration', '-Wno-int-conversion',
             '-include', str(config), '-include', str(build / 'shims/wine_ios_exit.h'), f'-I{build / "shims"}',
             f'-I{wine / "build-macos/dlls/ntdll"}', f'-I{wine / "dlls/ntdll"}', f'-I{wine / "dlls/ntdll/unix"}',
             f'-I{wine / "build-macos/include"}', f'-I{wine / "include"}', '-D__WINESRC__', '-DLTC_NO_PROTOTYPES',
             '-DLTC_SOURCE', '-D_NTSYSTEM_', '-D_ACRTIMP=', '-DWINBASEAPI=', '-DBINDIR="/usr/local/bin"',
             '-DLIBDIR="/usr/local/lib"', '-DDATADIR="/usr/local/share"', '-DSYSTEMDLLPATH=""', '-DWINE_UNIX_LIB',
             '-DWINE_IOS=1', '-Dget_thread_context=ntdll_get_thread_context', '-Dset_thread_context=ntdll_set_thread_context']
    r = subprocess.run(['xcrun', '-sdk', 'iphoneos', 'clang', *flags, str(build / 'virtual_ios.c')], capture_output=True, text=True)
    check('virtual_ios.c compiles for iOS (syntax only, pinned wine headers)', r.returncode == 0, r.stderr[-2000:])
    check('...and the new block adds no warning', 'check_addr' not in r.stderr, r.stderr[-2000:])
else:
    print('skip the iOS syntax check: no wine/build-macos/include/config.h (set WINE_SRC to a configured wine tree)')

rules = (root / 'build/tools/autotune_rules.py').read_text()
check('auto-tune knows the refusal as fixed in build 620', '"id": "wow-map-explicit-base-refused"' in rules and '"fixedIn": 620' in
      rules[rules.index('"id": "wow-map-explicit-base-refused"'):][:600] if '"id": "wow-map-explicit-base-refused"' in rules else False)
wf = (root / '.github/workflows/build-ipa.yml').read_text()
check('CI runs this check', 'python3 tests/host/check-wow-map-zero-bits.py' in wf)
print('PASS: WoW64 explicit section base' if ok else 'FAILED: WoW64 explicit section base')
sys.exit(0 if ok else 1)
