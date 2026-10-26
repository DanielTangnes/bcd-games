// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// ios_host_status.h: the engine's live numbers for BCD's system tests (tests/systests), read-only and off by default.
//
// The tests are Windows programs in the Wine desktop's Start menu (RAM test, JIT pool test, system info). They need what
// only the host knows: how much memory iOS charges the app right now and says is left, and how full this session's JIT pool is.
// The pool warmer thread (virtual_ios.c, ios_pool_warmer_thread) already wakes about every two seconds, every quarter of a
// second once the app holds more than 2.4 GB, and measures the footprint; it calls ios_host_status_tick(), which rewrites ONE
// small file, <dir>/host-live.txt, as C:\ProgramData\BCD\host-live.txt in the prefix:
//
//   seq=<n>                    +1 for each rewrite
//   footprint_mb, compressed_mb, available_mb   what iOS charges the app (phys_footprint), what is compressed, and what
//                              os_proc_available_memory() says is left (0: iOS gave no usable number)
//   swap_used_mb               what the swap tier holds in its file
//   pool_total_kb pool_head_kb pool_tail_kb pool_hole_kb pool_free_kb pool_virgin_kb poolc_total_kb poolc_used_kb
//                              the JIT pool (see ios_host_status_pool below): its span, the program and DLL copies (head), the emulator's
//                              code buffers (tail), the holes that are not pool memory, the ranges given back, what was never used, and
//                              region C; written by the two-second cycle, kept by the quarter-second one
//
// Off unless the app sets MADEIRA_HOST_STATUS=<directory> (BCDHostStatus.c does, only in the plain Windows desktop session,
// env.MADEIRA_HOST_STATUS = 0 turns it off): with it unset the tick returns at once and a session behaves exactly as before.
// The file is written to a temporary name and renamed over the old one, so a reader never sees half of it. Nothing allocates.
// tests/host/check-host-status.py compiles the plain part of this file on the Mac; the part that reads virtual_ios.c's statics is
// included there (IOS_HOST_STATUS_IN_VIRTUAL) and only checked for its shape.

#ifndef IOS_HOST_STATUS_H
#define IOS_HOST_STATUS_H

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct
{
    unsigned long long seq, footprint_mb, compressed_mb, available_mb, swap_used_mb;
    int have_pool;
    unsigned long long pool_total_kb, pool_head_kb, pool_tail_kb, pool_hole_kb, pool_free_kb, pool_virgin_kb;
    unsigned long long poolc_total_kb, poolc_used_kb;
} ios_host_status_rec;

/* How many bytes of the hole [off, end) lie inside [lo, hi). */
static inline size_t ios_host_status_overlap( size_t lo, size_t hi, size_t off, size_t end )
{
    if (end <= off || hi <= lo) return 0;
    if (off < lo) off = lo;
    if (end > hi) end = hi;
    return end > off ? end - off : 0;
}

/* The text of a record; the length, or 0 when `cap` is too small. */
static inline size_t ios_host_status_format( const ios_host_status_rec *r, char *buf, size_t cap )
{
    int n = snprintf( buf, cap, "seq=%llu\nfootprint_mb=%llu\ncompressed_mb=%llu\navailable_mb=%llu\nswap_used_mb=%llu\n",
                      r->seq, r->footprint_mb, r->compressed_mb, r->available_mb, r->swap_used_mb );
    if (n < 0 || (size_t)n >= cap) return 0;
    if (r->have_pool)
    {
        int m = snprintf( buf + n, cap - (size_t)n,
                          "pool_total_kb=%llu\npool_head_kb=%llu\npool_tail_kb=%llu\npool_hole_kb=%llu\npool_free_kb=%llu\n"
                          "pool_virgin_kb=%llu\npoolc_total_kb=%llu\npoolc_used_kb=%llu\n",
                          r->pool_total_kb, r->pool_head_kb, r->pool_tail_kb, r->pool_hole_kb, r->pool_free_kb,
                          r->pool_virgin_kb, r->poolc_total_kb, r->poolc_used_kb );
        if (m < 0 || (size_t)m >= cap - (size_t)n) return 0;
        n += m;
    }
    return (size_t)n;
}

/* <dir>/host-live.txt, replaced as a whole (temporary file, then rename); 1 on success. */
static inline int ios_host_status_write( const char *dir, const char *text, size_t len )
{
    char tmp[1024], dst[1024];
    size_t done = 0;
    int fd;

    if (snprintf( tmp, sizeof(tmp), "%s/host-live.tmp", dir ) >= (int)sizeof(tmp) ||
        snprintf( dst, sizeof(dst), "%s/host-live.txt", dir ) >= (int)sizeof(dst)) return 0;
    fd = open( tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644 );
    if (fd < 0) return 0;
    while (done < len)
    {
        ssize_t n = write( fd, text + done, len - done );
        if (n <= 0) { close( fd ); unlink( tmp ); return 0; }
        done += (size_t)n;
    }
    close( fd );
    if (rename( tmp, dst ) != 0) { unlink( tmp ); return 0; }
    return 1;
}

/* The directory from MADEIRA_HOST_STATUS, once: NULL when the status is off (unset, empty, "0" or too long). */
static inline const char *ios_host_status_dir( void )
{
    static int known;
    static char dir[900];

    if (!known)
    {
        const char *e = getenv( "MADEIRA_HOST_STATUS" );
        known = 1;
        if (e && e[0] && !(e[0] == '0' && !e[1]) && strlen( e ) < sizeof(dir)) strcpy( dir, e );
    }
    return dir[0] ? dir : NULL;
}

#ifdef IOS_HOST_STATUS_IN_VIRTUAL
/* ---- the part that reads virtual_ios.c: this header is included there, after the pool's statics ---- */

/* The swap tier's bytes in its file, defined much later in virtual_ios.c (a second tentative definition is allowed). */
static unsigned long long ios_swap_bytes;

/* What this record may say about the pool, in KB: its span, the head (program and DLL copies) and the tail (the emulator's code
 * buffers) without the holes they jumped, the holes, the reclaimed free list, what was never used, and region C. The free list is
 * read under the pool lock by try-lock only: when the lock is busy, the free-list figure of the last tick stays. */
static void ios_host_status_pool( ios_host_status_rec *r, unsigned long long *last_free_kb )
{
    size_t total = ios_jit_pool_size_global, head = jit_pool_offset, tail = ios_jit_tail_reserved;
    size_t hole_total = 0, hole_in_head = 0, hole_in_tail = 0, head_net, tail_net, usable, virgin = 0, free_bytes = 0;
    int i;

    if (!total) { r->have_pool = 0; return; }
    r->have_pool = 1;
    if (head > total) head = total;
    if (tail > total) tail = total;
    /* The two native holes are not pool memory. The head cursor and the tail carve both jump over them, so what they have
     * "used" counts the holes they passed: take those out, to say how much of the pool is really in use. */
    if (ios_jit_hole_end > ios_jit_hole_off)
    {
        hole_total += ios_jit_hole_end - ios_jit_hole_off;
        hole_in_head += ios_host_status_overlap( 0, head, ios_jit_hole_off, ios_jit_hole_end );
        hole_in_tail += ios_host_status_overlap( total - tail, total, ios_jit_hole_off, ios_jit_hole_end );
    }
    if (ios_jit_hole2_end > ios_jit_hole2_off)
    {
        hole_total += ios_jit_hole2_end - ios_jit_hole2_off;
        hole_in_head += ios_host_status_overlap( 0, head, ios_jit_hole2_off, ios_jit_hole2_end );
        hole_in_tail += ios_host_status_overlap( total - tail, total, ios_jit_hole2_off, ios_jit_hole2_end );
    }
    head_net = head > hole_in_head ? head - hole_in_head : 0;
    tail_net = tail > hole_in_tail ? tail - hole_in_tail : 0;
    usable = total > hole_total ? total - hole_total : 0;
    if (head_net + tail_net <= usable) virgin = usable - head_net - tail_net;
    if (pthread_mutex_trylock( &ios_pool_lock ) == 0)
    {
        for (i = 0; i < ios_pool_free_count && i < IOS_POOL_FREE_MAX; i++) free_bytes += ios_pool_freelist[i].size;
        pthread_mutex_unlock( &ios_pool_lock );
        *last_free_kb = free_bytes >> 10;
    }
    r->pool_total_kb = total >> 10;
    r->pool_head_kb = head_net >> 10;
    r->pool_tail_kb = tail_net >> 10;
    r->pool_hole_kb = hole_total >> 10;
    r->pool_free_kb = *last_free_kb;
    r->pool_virgin_kb = virgin >> 10;
    r->poolc_total_kb = ios_jit_low_size_global >> 10;
    r->poolc_used_kb = (ios_jit_low_reserved > ios_jit_low_size_global ? ios_jit_low_size_global : ios_jit_low_reserved) >> 10;
}

/* The pool warmer's hook. fast = 1 from its quarter-second loop (the footprint only; the pool figures of the last full cycle
 * stay), 0 from its two-second cycle. */
static void ios_host_status_tick( int fast )
{
    static ios_host_status_rec rec;
    static unsigned long long last_free_kb;
    static unsigned long long memsize;
    static int sized;
    const char *dir = ios_host_status_dir();
    char text[768];
    size_t n;
    task_vm_info_data_t vmi;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    extern size_t os_proc_available_memory( void );

    if (!dir) return;
    if (!sized)
    {
        size_t len = sizeof(memsize);
        if (sysctlbyname( "hw.memsize", &memsize, &len, NULL, 0 )) memsize = 0;
        sized = 1;
    }
    if (task_info( mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &cnt ) == KERN_SUCCESS)
    {
        rec.footprint_mb = (unsigned long long)vmi.phys_footprint >> 20;
        rec.compressed_mb = (unsigned long long)vmi.compressed >> 20;
    }
    {
        unsigned long long left = (unsigned long long)os_proc_available_memory();
        rec.available_mb = (left && !(memsize && left > memsize)) ? left >> 20 : 0;   /* a "no limit" sentinel is not a measurement */
    }
    rec.swap_used_mb = ios_swap_bytes >> 20;
    if (!fast) ios_host_status_pool( &rec, &last_free_kb );
    rec.seq++;
    n = ios_host_status_format( &rec, text, sizeof(text) );
    if (n) ios_host_status_write( dir, text, n );
}
#endif /* IOS_HOST_STATUS_IN_VIRTUAL */

#endif /* IOS_HOST_STATUS_H */
