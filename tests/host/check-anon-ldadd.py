#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Run the real anonymous-alias LDADDAL word emulator, including concurrent adds.

GTBQHV / DCE9MT / 9X8JNF (Slay the Spire 2, build 600) first fault on b8f50106,
LDADDAL W21,W6,[X8], with an existing writable alias. Only this previously
undecoded 32-bit AL family is enabled ONLY with MADEIRA_ANON_LDADDAL32=1;
default off and changing sessions preserve the old path. Invalid encodings,
registers and addresses decline without writing. No Wine or device is run.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
start = source.index('static int ios_mach_emulate_ldaddal32(')
end = source.index('\n}\n', start) + 3
get_start = source.index('static int ios_anon_ldaddal32_on(void)')
get_end = source.index('\n}\n', get_start) + 3
helper = source[get_start:get_end] + '\n' + source[start:end]
bridge = (root / 'app/Madeira/WineProcessBridge.m').read_text()
cleanup_start = bridge.index('static void wine_session_end(void)\n{')
cleanup_end = bridge.index('    // Stop wineserver', cleanup_start)
cleanup = bridge[cleanup_start:cleanup_end]
reset = 'unsetenv("MADEIRA_ANON_LDADDAL32");'
assert reset in cleanup, 'the shared normal/abandoned-session cleanup must reset the opt-in'
assert 'wine_session_end();' in bridge[bridge.index('void wine_session_abandon(void)\n{'):]
harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdlib.h>
''' + helper + '\nstatic void end_game_session(void) { ' + reset + ' }\n' + r'''
static uint32_t word __attribute__((aligned(16)));
static uint64_t returns[4];
static void *increment(void *arg) {
    uintptr_t id = (uintptr_t)arg;
    uint64_t g[29] = {0};
    g[21] = 1;
    for (int i = 0; i < 40000; ++i) {
        if (!ios_mach_emulate_ldaddal32(0xb8f50106u, (uintptr_t)&word, g)) return (void *)1;
        returns[id] += g[6];
    }
    return 0;
}
#define CHECK(x) do { if (!(x)) { printf("FAIL line %d\n", __LINE__); return 1; } } while (0)
int main(void) {
    uint64_t g[29], before[29];
    for (int i = 0; i < 29; ++i) g[i] = 0xaaaa000000000000ull + i;
    g[21] = 0xffffffff00000003ull;
    memcpy(before, g, sizeof g);
    word = 0xfffffffeu;
    CHECK(!unsetenv("MADEIRA_ANON_LDADDAL32"));
    CHECK(!ios_mach_emulate_ldaddal32(0xb8f50106u, (uintptr_t)&word, g));
    CHECK(word == 0xfffffffeu && !memcmp(g, before, sizeof g));
    const char *off[] = {"", "0", "true", "yes", "2", "01", "1x"};
    for (unsigned i = 0; i < sizeof off / sizeof *off; ++i) {
        CHECK(!setenv("MADEIRA_ANON_LDADDAL32", off[i], 1));
        CHECK(!ios_mach_emulate_ldaddal32(0xb8f50106u, (uintptr_t)&word, g));
        CHECK(word == 0xfffffffeu && !memcmp(g, before, sizeof g));
    }
    CHECK(!setenv("MADEIRA_ANON_LDADDAL32", "1", 1));
    CHECK(ios_mach_emulate_ldaddal32(0xb8f50106u, (uintptr_t)&word, g));
    CHECK(word == 1 && g[6] == 0xfffffffeull);
    for (int i = 0; i < 29; ++i) CHECK(i == 6 || g[i] == before[i]);
    /* Same proven instruction family, other register operands in this round. */
    word = 10; g[25] = 4;
    CHECK(ios_mach_emulate_ldaddal32(0xb8f90366u, (uintptr_t)&word, g));
    CHECK(word == 14 && g[6] == 10); /* Jetboard Joust: W25,W6,[X27] */
    word = 20; g[22] = 7;
    CHECK(ios_mach_emulate_ldaddal32(0xb8f60106u, (uintptr_t)&word, g));
    CHECK(word == 27 && g[6] == 20); /* Quaver: W22,W6,[X8] */
    /* Source and destination overlap: read the operand before replacing W21. */
    word = 7; g[21] = 9;
    CHECK(ios_mach_emulate_ldaddal32((0xb8f50106u & ~31u) | 21u, (uintptr_t)&word, g));
    CHECK(word == 16 && g[21] == 7);
    /* WZR as source adds zero; WZR as destination discards the old value. */
    word = 11; g[6] = 99;
    CHECK(ios_mach_emulate_ldaddal32((0xb8f50106u & ~(31u << 16)) | (31u << 16), (uintptr_t)&word, g));
    CHECK(word == 11 && g[6] == 11);
    g[21] = 5; memcpy(before, g, sizeof g);
    CHECK(ios_mach_emulate_ldaddal32((0xb8f50106u & ~31u) | 31u, (uintptr_t)&word, g));
    CHECK(word == 16 && !memcmp(before, g, sizeof g));
    const uint32_t refuse[] = {
        0xf8f50106u, /* X-width */
        0x38f50106u, 0x78f50106u, /* byte / halfword */
        0xb8350106u, 0xb8b50106u, 0xb8750106u, /* non-AL orderings */
        0xb8f51106u, 0xb8f58106u, /* LDCLR / SWP */
        0xc8e8ff60u, 0xf9000000u, /* CAS / STR */
        (0xb8f50106u & ~(31u << 16)) | (29u << 16),
        (0xb8f50106u & ~31u) | 30u,
    };
    memcpy(before, g, sizeof g);
    for (unsigned i = 0; i < sizeof refuse / sizeof *refuse; ++i) {
        CHECK(!ios_mach_emulate_ldaddal32(refuse[i], (uintptr_t)&word, g));
        CHECK(word == 16 && !memcmp(before, g, sizeof g));
    }
    CHECK(!ios_mach_emulate_ldaddal32(0xb8f50106u, 0, g));
    CHECK(!ios_mach_emulate_ldaddal32(0xb8f50106u, (uintptr_t)&word + 1, g));
    CHECK(word == 16 && !memcmp(before, g, sizeof g));
    pthread_t threads[4]; word = 0;
    for (uintptr_t i = 0; i < 4; ++i) CHECK(!pthread_create(&threads[i], 0, increment, (void *)i));
    for (int i = 0; i < 4; ++i) { void *result; CHECK(!pthread_join(threads[i], &result) && !result); }
    CHECK(word == 160000);
    /* Every fetch-add returned a distinct old value, not just a final total. */
    CHECK(returns[0] + returns[1] + returns[2] + returns[3] == 159999ull * 160000 / 2);
    /* Run the production session reset: an enabled game ends, then a game with
     * no key must go back to the old path in the same host process. */
    end_game_session();
    CHECK(getenv("MADEIRA_ANON_LDADDAL32") == NULL);
    memcpy(before, g, sizeof g);
    CHECK(!ios_mach_emulate_ldaddal32(0xb8f50106u, (uintptr_t)&word, g));
    CHECK(word == 160000 && !memcmp(before, g, sizeof g));
    puts("PASS: atomic LDADDAL word semantics, refusal, concurrency and session reset");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='bcd-anon-ldadd-') as tmp:
    path = Path(tmp)
    (path / 'check.c').write_text(harness)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-Wall', '-Wextra', '-Werror',
                    '-pthread', str(path / 'check.c'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)

branch = source[source.index('/* build 608: the first unhandled write'):source.index('/* ml350 DISCRIMINATOR:')]
assert 'if (!emulated && !in_jit && !anon_cas_handoff &&' in branch
assert '!(fault_addr & 3)' in branch
assert 'ios_jit_anon_alias_lookup( fault_addr + 3 ) == rw_addr + 3' in branch
assert 'ios_mach_emulate_ldaddal32(insn, rw_addr, state.__x)' in branch
assert 'if (!ios_anon_ldaddal32_on()) return 0;' in helper
assert 'run: python3 tests/host/check-anon-ldadd.py' in (root / '.github/workflows/build-ipa.yml').read_text()
print('PASS: default-off per-game gate and aligned, fully covered anonymous-alias path')
