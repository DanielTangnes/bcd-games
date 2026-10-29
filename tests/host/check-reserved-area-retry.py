#!/usr/bin/env python3
"""A MAP_FIXED over a guest window that the kernel refuses is retried at the next free range (small address maps only).

Shade: Wrath of Angels (39Z345, C534F0, Z5F6MG; build 576, iPhone13,4, iOS 18.6.2, 63 GB address map, 32-bit program):
a 0x11000-byte section map inside the guest window [0x400000000,0x500000000) ended in STATUS_NO_MEMORY with a 2 GB gap
free ("[laa] ml1070 SPILL", "[va-scan] FAILED window=0x400110000..0x500000000 ... errno=17"), and ucrtbase's init
failed (c0000142). The errno=17 is only map_free_area's no-clobber probe finding our own PROT_NONE reservation;
the placement itself is map_reserved_area's MAP_FIXED over that reservation, which returned NULL in silence, either
because its search found no range or because the MAP_FIXED failed; the log cannot tell which. The same logs show the
window refusing the program's image at its preferred base 0x410000000 (c0000017: the MAP_FIXED's ENOMEM or
create_view's allocation) and taking the relocated map at 0x401310000.

virtual_ios.c now retries the next free range after an ENOMEM from that MAP_FIXED (ios_reserved_retry), only when
ios_wow_small_va_slots is set (a small address map), and says why on the failing path: [reserved-area] (the refusal),
[va-scan] window room (what the free-range table holds), and STAGE= on the [map-sec] and ml985 refusals, so the next
log tells the refusal from the search from create_view. The retry is a recovery for the first reading, not a proof.

Round 579 (Shade 6NE7KH, build 578): on 578 the same refusal ended an 8 MB request (the game's Direct3D 9 buffer, then a
WoW64 stack): all 32 retries are 64 KB apart, so they cover 2 MB of range, and the [reserved-area] budget of eight lines
had been spent by the small requests at load time. Now: a request of 1 MB or more has its own budget, every refused candidate
and the kernel's regions across the refused range are logged (and what the first candidate after a refusal held before it
was mapped), and, only when the placement ended in NULL after a refusal on a small address map, the first refused
candidate is unmapped and mapped again without overwriting (ios_reserved_remap; env.MADEIRA_RESERVED_REMAP = 0 turns it off).
The retry loop itself is unchanged. The whole of map_reserved_area_inner is compiled and run against fakes: nothing but a
refused, unplaced chain reaches the new code, and a healthy placement reads no region.

Source checks (every host) hold the shape; the retry loop is then compiled and run against fakes.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
ok = True


def check(what, cond, detail=''):
    global ok
    print(('ok   ' if cond else 'FAIL ') + what + (('\n     ' + detail) if (detail and not cond) else ''))
    ok = ok and bool(cond)


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n}', start) + 2] + '\n'


retry_fn = function('static void *ios_reserved_retry(')
typedefs = source[source.index('typedef void *(*ios_reserved_once_fn)'):source.index('static void *ios_reserved_retry(')]
inner_fn = function('static void *map_reserved_area_inner( void *limit_low, void *limit_high, size_t size, int top_down,\n'
                    '                                      int unix_prot, size_t align_mask )\n{\n    struct ios_reserved_ctx')
once_fn = function('static void *map_reserved_area_once( void *limit_low, void *limit_high, void *ctx_, void **refused, int *err )\n{')
room_fn = function('static void ios_log_window_room(')

check('the retry loop only calls the placement again; it maps, protects and unmaps nothing itself',
      all(m not in retry_fn for m in ('mmap(', 'munmap(', 'mprotect(', 'anon_mmap', 'memset(', 'memcpy(')))
check('a retry happens only after the kernel said ENOMEM, only up to the given number of tries',
      'while (!ptr && refused && err == ENOMEM && n < max_tries)' in retry_fn)
check('each retry lies strictly above (bottom-up) or below (top-down) the refused address',
      'if (top_down) high = (char *)refused + size - 1;' in retry_fn
      and 'else low = (char *)refused + align_mask + 1;' in retry_fn)
check('the retry is on only on a small address map (ios_wow_small_va_slots), zero tries elsewhere',
      'ios_wow_small_va_slots && !ios_reserved_skip_now ? IOS_RESERVED_RETRY_MAX : 0' in inner_fn and '#define IOS_RESERVED_RETRY_MAX 32' in source)
check('the placement is still one MAP_FIXED over the reservation, and a failure of it is reported, not hidden',
      once_fn.count('anon_mmap_fixed(') == 1 and '*refused = ptr;' in once_fn and '*err = errno;' in once_fn)
check('a search that finds no range still returns NULL with no refusal recorded (nothing is retried)',
      once_fn.count('return NULL;') == 2 and 'refused' not in once_fn[:once_fn.index('if (top_down)')].replace('void **refused', ''))
check('the refusal is logged once-capped, with what Mach says about the address',
      '++ra_n <= 8' in inner_fn and 'ios_va_describe( first_refused' in inner_fn)
check('the free-range census reads only, and runs only on the failure path of a request that cannot relax',
      all(m not in room_fn for m in ('mmap(', 'munmap(', 'mprotect(', 'anon_mmap')) and 'room_n++ >= 8' in room_fn
      and 'if (!ptr && !ceiling_relaxable) ios_log_window_room( start, end, host_size, align_mask );' in source)
check('map_fixed_area (a fixed address) is untouched', source.count('static NTSTATUS map_fixed_area(') == 1
      and 'ios_reserved_retry' not in function('static NTSTATUS map_fixed_area('))

remap_fn = function('static void *ios_reserved_remap(')
check('the retry loop is as it was (the refused candidates are recorded by the placement, not by the loop)',
      retry_fn.count('once(') == 2 and 'ctx' in retry_fn and 'refused_list' not in retry_fn and 'ios_va_regions' not in retry_fn)
check('the last resort runs only when the placement is still NULL after a refusal, ENOMEM, a small address map, key on',
      'if (!ptr && first_err == ENOMEM && ios_wow_small_va_slots && ios_reserved_remap_enabled())' in inner_fn
      and inner_fn.index('if (first_refused)') < inner_fn.index('ios_reserved_remap( first_refused'))
check('the last resort touches only a candidate Wine calls free: no view, wholly inside one reserved area, not the JIT pool',
      'find_view_range( addr, size )' in remap_fn and 'mmap_is_in_reserved_area( addr, size ) != 1' in remap_fn
      and 'ios_jit_pool_intersects( addr, size )' in remap_fn
      and remap_fn.index('find_view_range') < remap_fn.index('munmap(') and remap_fn.index('ios_jit_pool_intersects') < remap_fn.index('munmap('))
check('the last resort puts the PROT_NONE reservation back when the no-overwrite map fails',
      'anon_mmap_fixed( addr, size, PROT_NONE, MAP_NORESERVE )' in remap_fn and remap_fn.index('anon_mmap_tryfixed(') < remap_fn.index('anon_mmap_fixed('))
check('the new kernel reads (regions, the candidate after a refusal) happen only after a refusal',
      once_fn.count('ios_va_regions(') == 1 and 'if (ptr && ctx->nrefused)' in once_fn
      and inner_fn.count('ios_va_regions(') == 1 and inner_fn.index('ios_va_regions(') > inner_fn.index('if (first_refused)'))
check('requests of 1 MB or more have a budget of their own (64, then every 64th); the small ones keep eight then every 256th',
      'int first_err, show = 0, big = size >= 0x100000;' in inner_fn
      and 'show = big ? (++ra_big_n <= 64 || !(ra_big_n % 64)) : (++ra_n <= 8 || !(ra_n % 256));' in inner_fn)
check('the first [reserved-area] line keeps its words (tools and earlier logs read them)',
      '"[reserved-area] #%lu MAP_FIXED over our own reservation refused: %p+0x%lx errno=%d (%s) | %s | "' in inner_fn
      and '"%s (%u refused in all; small address map retry %s) rev=ajan5-motor\\n"' in inner_fn)
check('the catalog lists env.MADEIRA_RESERVED_REMAP, on', '"env.MADEIRA_RESERVED_REMAP"' in (root / 'build/tools/gen-config-catalog.py').read_text())

# ---- round 623: the skip past the kernel's fixed regions (Hotline Miami 2 3NB0B0, Metro: Last Light QJANDC) ----
skip_fn = function('static void *ios_reserved_skip(')
scan_fn = function('static int ios_va_blocker_scan(')
blocker_fn = function('static int ios_va_blocker( const void *addr, size_t size, uintptr_t *blo, uintptr_t *bhi )\n{')
check('the skip and the scan only call the placement again and read the kernel through a callback; they map, protect and unmap nothing',
      all(m not in skip_fn + scan_fn for m in ('mmap(', 'munmap(', 'mprotect(', 'anon_mmap', 'memset(', 'memcpy(', 'mach_vm')))
check('the kernel is read by mach_vm_region only, and only the blocker query reaches it',
      'mach_vm_region(' in function('static int ios_va_region_next(') and 'ios_va_blocker_scan( (uintptr_t)addr, size, ios_va_region_next' in blocker_fn
      and source.count('ios_va_blocker(') == 4)   # forward declaration, definition, the skip, the last resort
check('a blocker is a region of MAXIMUM protection none (vm_region p/m 0/0), the one kind the log shows in every refusal',
      'unsigned n = 0, prot = 0;' in scan_fn.replace('\n', ' ') or 'unsigned n = 0, prot = 0;' in scan_fn)
check('the skip runs only in the request\'s last attempt, on a small address map, after an ENOMEM refusal, with its key on',
      'if (!ptr && ios_reserved_skip_now && ctx.last_err == ENOMEM && ios_wow_small_va_slots && ios_reserved_skip_enabled())' in inner_fn
      and inner_fn.index('ios_reserved_retry(') < inner_fn.index('ios_reserved_skip(') < inner_fn.index('ios_reserved_remap( first_refused')
      and 'ios_wow_small_va_slots && !ios_reserved_skip_now ? IOS_RESERVED_RETRY_MAX : 0' in inner_fn)
last_fn = function('static void *map_reserved_area_last(')
check('the last attempt is map_reserved_area_last: the flag set round one map_reserved_area call and cleared again, nowhere else',
      source.count('ios_reserved_skip_now = 1;') == 1 and last_fn.index('ios_reserved_skip_now = 1;') < last_fn.index('map_reserved_area(')
      < last_fn.index('ios_reserved_skip_now = 0;') and source.count('ios_reserved_skip_now = 0;') == 1)
call_at = source.index('map_reserved_area_last( start, end, host_size, top_down, unix_prot, align_mask )')
check('map_reserved_area_last is called once, on a small address map, only where map_view is about to return STATUS_NO_MEMORY for a request that may not relax',
      source.count('map_reserved_area_last(') == 2 and 'ios_wow_small_va_slots &&' in source[call_at - 200:call_at]
      and source.rindex('if (!ceiling_relaxable)', 0, call_at) > call_at - 900
      and 'return STATUS_NO_MEMORY;' in source[call_at:call_at + 700])
check('each skip step moves strictly past the last refusal and the steps are capped',
      '#define IOS_RESERVED_SKIP_MAX 64' in source and 'while (*jumps < IOS_RESERVED_SKIP_MAX)' in skip_fn
      and 'if (next_low <= (uintptr_t)refused || next_low >= (uintptr_t)high) break;' in skip_fn
      and 'if (blo <= size || blo <= (uintptr_t)low) break;' in skip_fn)
check('the skip ends at a placement, a refusal other than ENOMEM, a search that finds nothing, or a refusal no blocker explains',
      'if (ptr || !refused || err != ENOMEM) break;' in skip_fn and 'if (!ios_va_blocker( refused, size, &blo, &bhi )) break;' in skip_fn)
check('the last resort asks for a blocker before it unmaps (a region no munmap removes would only leave a hole)',
      remap_fn.index('ios_va_blocker( addr, size') < remap_fn.index('munmap(') and 'remap not tried: the range holds a kernel region' in remap_fn)
check('the placement records its newest refusal for the skip', 'ctx->last_refused = ptr; ctx->last_err = *err;' in once_fn)
check('the first [reserved-area] line keeps its words; the skip has a line of its own',
      '"[reserved-area] #%lu skip: %u step(s) past kernel regions' in inner_fn and 'rev=ajan58-skip' in inner_fn)
check('the catalog lists env.MADEIRA_RESERVED_SKIP, on', '"env.MADEIRA_RESERVED_SKIP"' in (root / 'build/tools/gen-config-catalog.py').read_text())

harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
''' + typedefs + retry_fn + r'''
/* a window of candidate 64 KB-aligned addresses; `bad` ones are refused with `bad_err` */
#define NCAND 8
static uintptr_t cand[NCAND];
static int bad[NCAND], bad_err = ENOMEM;
static unsigned calls;

static void *once_fake( void *low, void *high, void *ctx, void **refused, int *err )
{
    size_t size = *(size_t *)ctx;
    int i;
    (void)size; calls++;
    /* bottom-up: the lowest candidate in [low, high - size]; top-down is tested through `topdown` below */
    for (i = 0; i < NCAND; i++)
    {
        uintptr_t a = cand[i];
        if (a < (uintptr_t)low || a + size > (uintptr_t)high) continue;
        if (bad[i]) { *refused = (void *)a; *err = bad_err; return NULL; }
        return (void *)a;
    }
    return NULL;
}
static void *once_fake_td( void *low, void *high, void *ctx, void **refused, int *err )
{
    size_t size = *(size_t *)ctx;
    int i;
    calls++;
    for (i = NCAND - 1; i >= 0; i--)
    {
        uintptr_t a = cand[i];
        if (a < (uintptr_t)low || a + size > (uintptr_t)high) continue;
        if (bad[i]) { *refused = (void *)a; *err = bad_err; return NULL; }
        return (void *)a;
    }
    return NULL;
}

int main(void)
{
    size_t size = 0x14000, align_mask = 0xffff;
    unsigned n; void *first; int err, i;
    void *p;
    for (i = 0; i < NCAND; i++) { cand[i] = 0x400110000UL + (uintptr_t)i * 0x100000; bad[i] = 0; }
    void *lo = (void *)0x400110000UL, *hi = (void *)0x500000000UL;

    /* nothing refused: placed at the first range, no retry, nothing recorded */
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == (void *)cand[0] && n == 0 && first == NULL && calls == 1 );

    /* two refusals bottom-up: the third range is taken; the first refusal is the one reported */
    bad[0] = bad[1] = 1; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == (void *)cand[2] && n == 2 && first == (void *)cand[0] && err == ENOMEM && calls == 3 );

    /* the same on a 512 GB map (zero tries): the refusal is reported and nothing is retried, as before */
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 0, once_fake, &size, &n, &first, &err );
    assert( p == NULL && n == 1 && first == (void *)cand[0] && calls == 1 );

    /* top-down: the highest candidates are refused, the next lower is taken */
    memset( bad, 0, sizeof bad ); bad[NCAND - 1] = bad[NCAND - 2] = 1; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 1, align_mask, 32, once_fake_td, &size, &n, &first, &err );
    assert( p == (void *)cand[NCAND - 3] && n == 2 && first == (void *)cand[NCAND - 1] && calls == 3 );

    /* only ENOMEM is retried: EEXIST (someone else's mapping) is not */
    memset( bad, 0, sizeof bad ); bad[0] = 1; bad_err = EEXIST; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == NULL && n == 1 && err == EEXIST && calls == 1 );
    bad_err = ENOMEM;

    /* the cap holds */
    for (i = 0; i < NCAND; i++) bad[i] = 1; calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 3, once_fake, &size, &n, &first, &err );
    assert( p == NULL && calls == 4 && n == 4 );

    /* every candidate refused and nothing left: the loop ends with NULL */
    calls = 0;
    p = ios_reserved_retry( lo, hi, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == NULL && calls == NCAND + 1 && n == NCAND );

    /* a search that finds no range at all is not a refusal */
    memset( bad, 0, sizeof bad ); calls = 0;
    p = ios_reserved_retry( (void *)0x600000000UL, (void *)0x700000000UL, size, 0, align_mask, 32, once_fake, &size, &n, &first, &err );
    assert( p == NULL && n == 0 && first == NULL && calls == 1 );

    puts( "PASS: retry after ENOMEM (bottom-up, top-down), none on a 512 GB map, none for other errors, capped, none without a refusal" );
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='reserved-area-retry-') as directory:
    temp = Path(directory)
    unit = temp / 'retry.c'
    unit.write_text(harness)
    exe = temp / 'retry'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE', '-Wall', '-Wextra',
                    '-Werror', str(unit), '-o', str(exe)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    check('the retry loop behaves against fake placements', r.returncode == 0, r.stderr)

# ---- the whole placement (map_reserved_area_inner) against fakes: the last resort, the budgets, the healthy path ----
ctx_struct = source[source.index('struct ios_reserved_ctx\n{'):]
ctx_struct = ctx_struct[:ctx_struct.index('};') + 3]
remap_region = source[source.index('static int ios_reserved_remap_enabled(void)'):source.index('/* remap-test:end */')]
skip_region = source[source.index('#define IOS_RESERVED_SKIP_MAX 64'):source.index('/* skip-test:end */')]
harness2 = r"""
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#define IOS_RESERVED_RETRY_MAX 32
struct file_view { int x; };
typedef unsigned long SIZE_T;
/* ---- the kernel and Wine's tables, faked ---- */
static int view_overlaps, in_area = 1, pool_hit, unmap_rc, unmap_errno = EACCES, tryfixed_ok = 1, restore_ok = 1;
static unsigned n_unmap, n_try, n_restore, n_regions, n_describe;
static void *last_unmap, *last_try, *last_restore;
static int last_try_prot = -1, last_restore_prot = -1;
static struct file_view dummy_view;
static struct file_view *find_view_range( const void *a, size_t s ) { (void)a; (void)s; return view_overlaps ? &dummy_view : NULL; }
static int mmap_is_in_reserved_area( void *a, SIZE_T s ) { (void)a; (void)s; return in_area; }
static int ios_jit_pool_intersects( const void *a, size_t s ) { (void)a; (void)s; return pool_hit; }
static void ios_pool_va_warn( const char *w, const void *a, size_t s ) { (void)w; (void)a; (void)s; }
static int fake_munmap( void *a, size_t s ) { (void)s; n_unmap++; last_unmap = a; if (unmap_rc) errno = unmap_errno; return unmap_rc; }
static void *anon_mmap_tryfixed( void *a, size_t s, int prot, int flags ) { (void)s; (void)flags; n_try++; last_try = a; last_try_prot = prot; if (tryfixed_ok) return a; errno = ENOMEM; return MAP_FAILED; }
void *anon_mmap_fixed( void *a, size_t s, int prot, int flags ) { (void)s; (void)flags; n_restore++; last_restore = a; last_restore_prot = prot; if (restore_ok) return a; errno = ENOMEM; return MAP_FAILED; }
#define munmap fake_munmap
static unsigned ios_wow_small_va_slots = 12;
static char logbuf[200000]; static unsigned nlines_first, nlines_detail, nlines_last;
static int dprintf_fake( int fd, const char *fmt, ... )
{
    char line[1500]; va_list ap; (void)fd;
    va_start( ap, fmt ); vsnprintf( line, sizeof(line), fmt, ap ); va_end( ap );
    if (strstr( line, " detail: " )) nlines_detail++;
    else if (strstr( line, "last resort at" ) && !strstr( line, "MAP_FIXED over" )) nlines_last++;
    else if (strstr( line, "MAP_FIXED over our own reservation refused" )) nlines_first++;
    if (strlen( logbuf ) + strlen( line ) < sizeof(logbuf) - 2) strcat( logbuf, line );
    return 0;
}
#define dprintf dprintf_fake
static void ios_va_describe( void *a, char *b, size_t n ) { (void)a; n_describe++; snprintf( b, n, "OCCUPIED fake prot=0/0" ); }
static void ios_va_regions( void *a, size_t s, char *b, size_t n ) { (void)a; (void)s; n_regions++; snprintf( b, n, "0xA+0x10000 0/0" ); }
/* the kernel's regions of maximum protection none ("bands", ascending): a MAP_FIXED over a range that touches one is refused (ENOMEM) */
#define NBANDS 4
static uintptr_t band_lo[NBANDS], band_hi[NBANDS];
static unsigned nbands, n_blocker;
static int comb;   /* bands every 32 MB, 1 MB wide, from 0x40f800000 on: no 32 MB range is free of them */
static int comb_overlap( uintptr_t x, uintptr_t y, uintptr_t *lo, uintptr_t *hi )
{
    uintptr_t k = x <= 0x40f800000UL ? 0 : (x - 0x40f800000UL) / 0x2000000UL, l, h;
    for (;; k++)
    {
        l = 0x40f800000UL + k * 0x2000000UL; h = l + 0x100000;
        if (l >= y) return 0;
        if (h > x) { *lo = l; *hi = h; return 1; }
    }
}
static int ios_va_blocker( const void *a, size_t s, uintptr_t *lo, uintptr_t *hi )
{
    uintptr_t x = (uintptr_t)a, y = x + s; unsigned i;
    n_blocker++;
    if (comb) return comb_overlap( x, y, lo, hi );
    for (i = 0; i < nbands; i++) if (band_lo[i] < y && band_hi[i] > x) { *lo = band_lo[i]; *hi = band_hi[i]; return 1; }
    return 0;
}
""" + ctx_struct + typedefs + retry_fn + remap_region + skip_region + r"""
/* the scripted placement: the first `refuse` candidates (64 KB apart from 0x40f8c0000) are refused with `ref_err`, then one is taken (or never) */
static unsigned refuse, ref_err = ENOMEM, called; static int never_place;
static void *map_reserved_area_once( void *limit_low, void *limit_high, void *ctx_, void **refused, int *err );
""" + inner_fn + r"""
static void *map_reserved_area_once( void *limit_low, void *limit_high, void *ctx_, void **refused, int *err )
{
    struct ios_reserved_ctx *ctx = ctx_;
    uintptr_t lo = (uintptr_t)limit_low, hi = (uintptr_t)limit_high, a;
    void *ptr;
    unsigned i;
    int touches = 0;
    called++;
    if (ctx->top_down)
    {
        if (hi < ctx->size) return NULL;
        a = (hi - ctx->size) & ~(uintptr_t)ctx->align_mask;
        if (a < lo) return NULL;                            /* the search finds no range: not a refusal */
    }
    else
    {
        a = lo > 0x40f8c0000UL ? lo : 0x40f8c0000UL;
        a = (a + ctx->align_mask) & ~(uintptr_t)ctx->align_mask;
        if (a + ctx->size > hi) return NULL;
    }
    ptr = (void *)a;
    for (i = 0; i < nbands; i++) if (band_lo[i] < a + ctx->size && band_hi[i] > a) touches = 1;
    if (comb) { uintptr_t cl, ch; touches |= comb_overlap( a, a + ctx->size, &cl, &ch ); }
    if (ptr && ctx->nrefused) { ctx->next_pre_addr = ptr; ios_va_regions( ptr, ctx->size, ctx->next_pre, sizeof(ctx->next_pre) ); }
    if (never_place || touches || ctx->nrefused < refuse)
    {
        *refused = ptr; *err = (int)ref_err;
        if (ctx->nrefused < 40) ctx->refused_list[ctx->nrefused] = ptr;
        ctx->nrefused++;
        ctx->last_refused = ptr; ctx->last_err = (int)ref_err;
        return NULL;
    }
    return ptr;
}
static void *place( size_t size, int unix_prot )
{
    called = 0;
    return map_reserved_area_inner( (void *)0x400110000UL, (void *)0x500000000UL, size, 0, unix_prot, 0xffff );
}
static void *place_td( size_t size, int unix_prot )
{
    called = 0;
    return map_reserved_area_inner( (void *)0x400110000UL, (void *)0x500000000UL, size, 1, unix_prot, 0xffff );
}
/* the request's last attempt (map_reserved_area_last sets the flag round the same call) */
static void *place_last( size_t size, int unix_prot )
{
    void *r;
    ios_reserved_skip_now = 1; r = place( size, unix_prot ); ios_reserved_skip_now = 0;
    return r;
}
static void *place_td_last( size_t size, int unix_prot )
{
    void *r;
    ios_reserved_skip_now = 1; r = place_td( size, unix_prot ); ios_reserved_skip_now = 0;
    return r;
}
static void reset( void )
{
    n_unmap = n_try = n_restore = n_regions = n_describe = 0; last_unmap = last_try = last_restore = NULL;
    view_overlaps = pool_hit = unmap_rc = 0; in_area = 1; tryfixed_ok = restore_ok = 1; ref_err = ENOMEM; never_place = 0;
    ios_wow_small_va_slots = 12; refuse = 0; logbuf[0] = 0; nlines_first = nlines_detail = nlines_last = 0;
    nbands = n_blocker = 0; comb = 0; ios_reserved_skip_now = 0;
}
static struct { uintptr_t lo, hi; unsigned prot; } fmap[16];
static unsigned nfmap, freads; static int many;
static void add_region( uintptr_t lo, uintptr_t hi, unsigned prot ) { fmap[nfmap].lo = lo; fmap[nfmap].hi = hi; fmap[nfmap].prot = prot; nfmap++; }
static int fake_next( uintptr_t a, uintptr_t *lo, uintptr_t *hi, unsigned *m )
{
    unsigned i;
    freads++;
    if (many) { *lo = a & ~0xfffUL; *hi = *lo + 0x1000; *m = 7; return 1; }
    for (i = 0; i < nfmap; i++) if (fmap[i].hi > a) { *lo = fmap[i].lo; *hi = fmap[i].hi; *m = fmap[i].prot; return 1; }
    return 0;
}
int main( int argc, char **argv )
{
    void *p;
    int i;
    if (argc > 1 && !strcmp( argv[1], "budget" ))
    {
    /* log budgets: small requests eight lines then every 256th; 1 MB and more 64 then every 64th */
    reset(); never_place = 1; ios_wow_small_va_slots = 0;       /* no last resort, one refusal per chain: only the logging */
    for (i = 0; i < 300; i++) place( 0x14000, 3 );
    {
        assert( nlines_first == 8 + 1 );     /* eight, then the 256th */
    }
    reset(); never_place = 1; ios_wow_small_va_slots = 0;
    for (i = 0; i < 200; i++) place( 0x810000, 3 );
    assert( nlines_first == 64 + 2 );        /* 64, then the 128th and the 192nd */

        puts( "PASS: log budgets" );
        return 0;
    }
    if (argc > 1 && !strcmp( argv[1], "off" ))
    {
        /* env.MADEIRA_RESERVED_REMAP = 0 (read once per process): the retry and the logging as before, no last resort */
        reset(); never_place = 1; p = place( 0x810000, 3 );
        assert( p == NULL && n_unmap == 0 && n_try == 0 && n_restore == 0 && called == 33 && nlines_first == 1 && nlines_detail == 1 );
        assert( !strstr( logbuf, "last resort" ) );
        puts( "PASS: MADEIRA_RESERVED_REMAP=0 keeps the retry and the log, and does no last resort" );
        return 0;
    }

    if (argc > 1 && !strcmp( argv[1], "skipoff" ))
    {
        /* env.MADEIRA_RESERVED_SKIP = 0 (read once per process): the plain retries only, as before round 623 */
        reset(); nbands = 1; band_lo[0] = 0x40f900000UL; band_hi[0] = 0x40fc00000UL;
        p = place_last( 0x810000, 3 );
        assert( p == NULL && called == 1 && n_blocker == 1 /* only the remap guard asks */ && n_unmap == 0 && n_try == 0 );
        assert( !strstr( logbuf, "skip:" ) && strstr( logbuf, "NOT placed" ) && strstr( logbuf, "remap not tried: the range holds a kernel region" ) );
        puts( "PASS: MADEIRA_RESERVED_SKIP=0 keeps the plain retries and does no skip" );
        return 0;
    }
    if (argc > 1 && !strcmp( argv[1], "scan" ))
    {
        /* the scan of the kernel's regions, against a fake map */
        uintptr_t lo, hi;
        nfmap = freads = 0; many = 0;
        assert( !ios_va_blocker_scan( 0x410000000UL, 0x1000000, fake_next, &lo, &hi ) );                       /* no region at all */
        add_region( 0x410000000UL, 0x410004000UL, 7 ); add_region( 0x410004000UL, 0x410044000UL, 7 );
        assert( !ios_va_blocker_scan( 0x410000000UL, 0x1000000, fake_next, &lo, &hi ) );                       /* regions that MAP_FIXED replaces */
        nfmap = 0;
        add_region( 0x410000000UL, 0x410004000UL, 7 ); add_region( 0x410004000UL, 0x410044000UL, 0 ); add_region( 0x41bb60000UL, 0x420000000UL, 7 );
        assert( ios_va_blocker_scan( 0x404960000UL, 0x17010000, fake_next, &lo, &hi ) && lo == 0x410004000UL && hi == 0x410044000UL );   /* Metro */
        nfmap = 0;
        add_region( 0x401000000UL, 0x401030000UL, 0 );
        assert( ios_va_blocker_scan( 0x401010000UL, 0x20000, fake_next, &lo, &hi ) && lo == 0x401000000UL && hi == 0x401030000UL );     /* begins below the range */
        nfmap = 0;
        add_region( 0x402e00000UL, 0x402e10000UL, 0 ); add_region( 0x402e10000UL, 0x402e20000UL, 0 ); add_region( 0x402e20000UL, 0x402e24000UL, 0 );
        add_region( 0x402e24000UL, 0x402e30000UL, 7 ); add_region( 0x402e40000UL, 0x402e50000UL, 0 );
        assert( ios_va_blocker_scan( 0x402e00000UL, 0x100000, fake_next, &lo, &hi ) && lo == 0x402e00000UL && hi == 0x402e24000UL );    /* adjacent ones merge, the run ends at a region that is not one */
        nfmap = 0;
        add_region( 0x402e00000UL, 0x402e10000UL, 0 ); add_region( 0x402e30000UL, 0x402e40000UL, 0 );
        assert( ios_va_blocker_scan( 0x402e00000UL, 0x100000, fake_next, &lo, &hi ) && lo == 0x402e00000UL && hi == 0x402e10000UL );    /* a gap ends the run: the first one only */
        nfmap = 0;
        add_region( 0x410000000UL, 0x410010000UL, 0 );
        assert( !ios_va_blocker_scan( 0x404960000UL, 0x1000000, fake_next, &lo, &hi ) );                       /* a blocker beyond the range is none */
        many = 1; freads = 0;
        assert( !ios_va_blocker_scan( 0x400000000UL, 0x100000000UL, fake_next, &lo, &hi ) && freads <= 8192 );                          /* capped */
        puts( "PASS: scan" );
        return 0;
    }

    /* healthy: placed first time: nothing read from the kernel, nothing logged, no remap */
    reset(); p = place( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && n_regions == 0 && n_describe == 0 && n_unmap == 0 && logbuf[0] == 0 );

    /* the 578 small case: nine refusals, the retry places it: logged, but no last resort */
    reset(); refuse = 9; p = place( 0x14000, 3 );
    assert( p == (void *)(0x40f8c0000UL + 9 * 0x10000UL) && n_unmap == 0 && n_try == 0 && nlines_first == 1 && nlines_detail == 1 );
    assert( strstr( logbuf, "it took the mapping" ) && strstr( logbuf, "9 candidate(s) refused" ) && !strstr( logbuf, "last resort" ) );

    /* the 578 Shade 8 MB case: every retry refused (33 candidates): the last resort maps the FIRST refused candidate */
    reset(); never_place = 1; p = place( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && n_unmap == 1 && last_unmap == (void *)0x40f8c0000UL && n_try == 1 && last_try == last_unmap
            && last_try_prot == 3 && n_restore == 0 );
    assert( strstr( logbuf, "munmap then a no-overwrite map placed it" ) && strstr( logbuf, "(it was refused too)" ) && strstr( logbuf, "[reserved-area] #1 detail" ) );
    assert( strstr( logbuf, "the last resort placed it" ) );
    assert( strstr( logbuf, "33 candidate(s) refused" ) && strstr( logbuf, "(>= 1 MB, own budget)" ) );

    /* the no-overwrite map fails too: the reservation goes back as PROT_NONE and the request fails as before */
    reset(); never_place = 1; tryfixed_ok = 0; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 1 && n_try == 1 && n_restore == 1 && last_restore == (void *)0x40f8c0000UL && last_restore_prot == PROT_NONE );
    assert( strstr( logbuf, "reservation put back" ) );
    reset(); never_place = 1; tryfixed_ok = 0; restore_ok = 0; p = place( 0x810000, 3 );
    assert( p == NULL && strstr( logbuf, "reservation NOT put back" ) );

    /* munmap refused: nothing changed, nothing else called */
    reset(); never_place = 1; unmap_rc = -1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 1 && n_try == 0 && n_restore == 0 && strstr( logbuf, "munmap failed errno=" ) );

    /* a view, a partial area or the JIT pool in the way: never touched */
    reset(); never_place = 1; view_overlaps = 1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 && n_try == 0 && n_restore == 0 && strstr( logbuf, "a view overlaps it" ) );
    reset(); never_place = 1; in_area = -1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 && strstr( logbuf, "not wholly inside one reserved area" ) );
    reset(); never_place = 1; in_area = 0; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 );
    reset(); never_place = 1; pool_hit = 1; p = place( 0x810000, 3 );
    assert( p == NULL && n_unmap == 0 && strstr( logbuf, "touches the JIT pool" ) );

    /* a 512 GB map (no small-map slots): one refusal reported, nothing retried, nothing remapped, as before */
    reset(); never_place = 1; ios_wow_small_va_slots = 0; p = place( 0x810000, 3 );
    assert( p == NULL && called == 1 && n_unmap == 0 && n_try == 0 && nlines_first == 1 );

    /* another error than ENOMEM (someone else's mapping): neither retried nor remapped */
    reset(); never_place = 1; ref_err = EEXIST; p = place( 0x810000, 3 );
    assert( p == NULL && called == 1 && n_unmap == 0 );

    /* ---- round 623: the skip past the kernel's fixed regions (ios_reserved_skip), the request's LAST attempt only ---- */
    /* any other placement (the LAA pre-attempt, the biased first try ...) never skips, whatever the kernel holds: plain 33 candidates, then NULL;
     * the last resort does not unmap a range that holds a blocker */
    reset(); nbands = 1; band_lo[0] = 0x40f900000UL; band_hi[0] = 0x40fc00000UL;
    p = place( 0x810000, 3 );
    assert( p == NULL && called == 33 && n_blocker == 1 && n_unmap == 0 && n_try == 0 && n_restore == 0 && !strstr( logbuf, "skip:" ) );
    assert( strstr( logbuf, "NOT placed" ) && strstr( logbuf, "remap not tried: the range holds a kernel region no munmap removes (0x40f900000+0x300000" ) );

    /* the last attempt, no blocker known: the first candidate is refused (nothing explains it), nothing more from the skip; the last resort as before */
    reset(); never_place = 1; p = place_last( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && called == 1 && n_blocker >= 1 && !strstr( logbuf, "skip:" ) && n_unmap == 1 );

    /* Hotline Miami 2 / Metro: the last attempt jumps the band at once (the plain steps were refused already) and places beyond it */
    reset(); nbands = 1; band_lo[0] = 0x40f900000UL; band_hi[0] = 0x40fc00000UL;
    p = place_last( 0x810000, 3 );
    assert( p == (void *)0x40fc00000UL && called == 2 && n_unmap == 0 && n_try == 0 && n_restore == 0 );
    assert( nlines_first == 1 && nlines_detail == 1 && strstr( logbuf, "skip: 1 step(s) past kernel regions" ) );
    assert( strstr( logbuf, "the last 0x40f900000+0x300000" ) && strstr( logbuf, "the retry placed it past the kernel's fixed regions" ) );
    assert( strstr( logbuf, "(1 refused in all" ) && strstr( logbuf, "(it took the mapping)" ) && !strstr( logbuf, "last resort" ) );
    assert( strstr( logbuf, "the placement took a range beyond it" ) && strstr( logbuf, "rev=ajan58-skip" ) );

    /* two bands: the second is met after the first jump and skipped as well */
    reset(); nbands = 2; band_lo[0] = 0x40f900000UL; band_hi[0] = 0x40fc00000UL; band_lo[1] = 0x40fd00000UL; band_hi[1] = 0x40fe00000UL;
    p = place_last( 0x810000, 3 );
    assert( p == (void *)0x40fe00000UL && called == 3 && n_unmap == 0 && strstr( logbuf, "skip: 2 step(s)" ) );

    /* top-down: an 8 MB band below the top; the skip ends the next range at its start */
    reset(); nbands = 1; band_lo[0] = 0x4ff000000UL; band_hi[0] = 0x4ff800000UL;
    p = place_td_last( 0x810000, 3 );
    assert( p == (void *)0x4fe7f0000UL && called == 2 && n_unmap == 0 && strstr( logbuf, "skip: 1 step(s)" ) );

    /* a band that fills the window to its top: nothing to place, nothing unmapped, the last resort not tried (it would only leave a hole) */
    reset(); nbands = 1; band_lo[0] = 0x40f800000UL; band_hi[0] = 0x500000000UL;
    p = place_last( 0x810000, 3 );
    assert( p == NULL && called == 1 && n_unmap == 0 && n_try == 0 && n_restore == 0 );
    assert( strstr( logbuf, "NOT placed" ) && strstr( logbuf, "remap not tried: the range holds a kernel region no munmap removes (0x40f800000+0xf" ) );
    assert( !strstr( logbuf, "skip:" ) );   /* the one step that could be taken was past the window: not taken */

    /* bands everywhere: the skip is capped at IOS_RESERVED_SKIP_MAX steps and then fails as before */
    reset(); comb = 1;
    p = place_last( 0x2000000, 3 );
    assert( p == NULL && called == 1 + 64 && n_unmap == 0 && strstr( logbuf, "skip: 64 step(s)" ) && strstr( logbuf, "still NOT placed" ) );

    /* a refusal other than ENOMEM is neither retried nor skipped; a 512 GB map neither */
    reset(); nbands = 1; band_lo[0] = 0x40f900000UL; band_hi[0] = 0x40fc00000UL; ref_err = EEXIST;
    p = place_last( 0x810000, 3 );
    assert( p == NULL && called == 1 && !strstr( logbuf, "skip:" ) );
    reset(); nbands = 1; band_lo[0] = 0x40f900000UL; band_hi[0] = 0x40fc00000UL; ios_wow_small_va_slots = 0;
    p = place_last( 0x810000, 3 );
    assert( p == NULL && called == 1 && !strstr( logbuf, "skip:" ) && n_unmap == 0 );

    /* healthy and merely retried placements read no blocker: nothing changes for them */
    reset(); p = place( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && n_blocker == 0 );
    reset(); p = place_last( 0x810000, 3 );
    assert( p == (void *)0x40f8c0000UL && n_blocker == 0 && logbuf[0] == 0 );
    reset(); refuse = 9; p = place( 0x14000, 3 );
    assert( p == (void *)(0x40f8c0000UL + 9 * 0x10000UL) && n_blocker == 0 && !strstr( logbuf, "skip:" ) );

    puts( "PASS: nothing but a refused, unplaced chain reaches the new code; the last resort places, restores or does nothing" );
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix='reserved-area-remap-') as directory:
    temp = Path(directory)
    unit = temp / 'remap.c'
    unit.write_text(harness2)
    exe = temp / 'remap'
    r = subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-D_DARWIN_C_SOURCE', '-Wall', '-Wno-unused-function', '-Wno-unused-variable',
                        '-fsanitize=address,undefined', str(unit), '-o', str(exe)], capture_output=True, text=True)
    check('the placement, the last resort and the logging compile on the host', r.returncode == 0, r.stderr[-2500:])
    if r.returncode == 0:
        r = subprocess.run([str(exe)], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0'})
        sys.stdout.write(r.stdout)
        check('map_reserved_area_inner against fake kernel and tables', r.returncode == 0, (r.stdout + r.stderr)[-2500:])
        r = subprocess.run([str(exe), 'off'], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0', 'MADEIRA_RESERVED_REMAP': '0'})
        sys.stdout.write(r.stdout)
        check('env.MADEIRA_RESERVED_REMAP = 0 turns the last resort off', r.returncode == 0, (r.stdout + r.stderr)[-1500:])
        r = subprocess.run([str(exe), 'skipoff'], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0', 'MADEIRA_RESERVED_SKIP': '0'})
        sys.stdout.write(r.stdout)
        check('env.MADEIRA_RESERVED_SKIP = 0 turns the skip off', r.returncode == 0, (r.stdout + r.stderr)[-1500:])
        r = subprocess.run([str(exe), 'scan'], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0'})
        sys.stdout.write(r.stdout)
        check('the scan for a kernel region of maximum protection none, against a fake map', r.returncode == 0, (r.stdout + r.stderr)[-1500:])
        for value in ('1', '', '00', 'no'):
            r = subprocess.run([str(exe)], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0', 'MADEIRA_RESERVED_SKIP': value})
            check('MADEIRA_RESERVED_SKIP=%r leaves the skip on (only "0" turns it off)' % value, r.returncode == 0, (r.stdout + r.stderr)[-800:])
        r = subprocess.run([str(exe), 'budget'], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0'})
        sys.stdout.write(r.stdout)
        check('the log budgets: small requests eight lines then every 256th, 1 MB and more 64 then every 64th', r.returncode == 0, (r.stdout + r.stderr)[-1500:])
        for value in ('1', '', '00', 'no'):
            r = subprocess.run([str(exe)], capture_output=True, text=True, env={**os.environ, 'ASAN_OPTIONS': 'symbolize=0', 'MADEIRA_RESERVED_REMAP': value})
            check('MADEIRA_RESERVED_REMAP=%r leaves it on (only "0" turns it off)' % value, r.returncode == 0, (r.stdout + r.stderr)[-800:])
sys.exit(0 if ok else 1)
