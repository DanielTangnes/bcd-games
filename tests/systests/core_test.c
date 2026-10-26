// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// core_test.c: runs core.h on the Mac (tests/host/check-systests.py builds and runs it). The important part is the RAM test's
// loop (ram_drive) against thousands of made-up devices: whatever the limit, the start, the speed of the device, the size of
// the pieces, a background process that grows, a host that updates every quarter of a second or every two, or stops
// updating, the app must never be taken past its limit, and when the test stops at the limit it must have come close to it.

#include <stdlib.h>
#include "core.h"

static int fails, checks;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* ------------------------------------------------------------------ the made-up device */

typedef struct {
    double t_ms;
    u64 limit;              /* MB */
    double fp;              /* true footprint, MB (fractional while a piece is being touched) */
    double bg_rate;         /* MB per second of growth by something else */
    double bg_total;
    double ms_per_mb;       /* time to touch a MB */
    int host_updates;       /* 0: the host has stopped writing */
    double next_tick;
    u64 seq;
    double sample_fp;       /* the footprint at the last tick */
    int report_available;   /* 1: os_proc_available_memory gives a number, 0: only the limit and the footprint */
    int killed;
    double peak;
    u64 last_seq_wanted;
} dev;

static double dev_period(const dev *d) { return d->fp > 2400 ? 250.0 : 2000.0; }

static void dev_step(dev *d, double dt, double touch_mb)
{
    double bg = d->bg_rate * dt / 1000.0;
    d->t_ms += dt;
    d->fp += touch_mb + bg;
    d->bg_total += bg;
    if (d->fp > d->peak) d->peak = d->fp;
    if (d->fp > (double)d->limit) d->killed = 1;
    while (d->host_updates && d->t_ms >= d->next_tick) {
        d->seq++;
        d->sample_fp = d->fp;
        d->next_tick += dev_period(d);
    }
}

static int dev_take(void *ctx, u64 chunk_mb)
{
    dev *d = (dev *)ctx;
    double total = d->ms_per_mb * (double)chunk_mb, done = 0;
    while (done < total && !d->killed) {
        double dt = total - done < 5.0 ? total - done : 5.0;
        dev_step(d, dt, dt / total * (double)chunk_mb);
        done += dt;
    }
    return !d->killed;
}

static int dev_sample(void *ctx, u64 *avail)
{
    dev *d = (dev *)ctx;
    double waited = 0;
    u64 want = d->last_seq_wanted + 2;

    while (d->seq < want) {
        if (waited >= 5000.0) return 0;
        dev_step(d, 10.0, 0.0);
        waited += 10.0;
    }
    d->last_seq_wanted = d->seq;
    *avail = d->report_available ? (u64)((double)d->limit - d->sample_fp) : 0;
    if (!d->report_available) *avail = ram_base_avail(d->limit, (u64)d->sample_fp, 0);
    return 1;
}

static int dev_never_aborted(void *ctx) { (void)ctx; return 0; }

static void sim_one(u64 limit, u64 f0, u64 chunk, double bg, double ms_per_mb, int host_updates, int report_available, u64 target)
{
    dev d;
    ram_state st;
    ram_io io;
    int end;
    u64 head = 0, margin = ram_margin_mb(limit);

    memset(&d, 0, sizeof d);
    d.limit = limit;
    d.fp = (double)f0;
    d.bg_rate = bg;
    d.ms_per_mb = ms_per_mb;
    d.host_updates = host_updates;
    d.report_available = report_available;
    d.next_tick = 0;
    d.peak = d.fp;
    dev_step(&d, 0.0, 0.0);                      /* the first sample, before the test starts */
    d.last_seq_wanted = d.seq;

    memset(&st, 0, sizeof st);
    st.target_mb = target;
    st.chunk_mb = chunk;
    st.margin_mb = margin;
    st.blind_cap_mb = limit / 4 < 2048 ? limit / 4 : 2048;
    st.base_avail_mb = host_updates ? ram_base_avail(limit, (u64)d.sample_fp, report_available ? limit - (u64)d.sample_fp : 0) : 0;
    st.fresh = host_updates ? 1 : 0;
    io.ctx = &d;
    io.take = dev_take;
    io.sample = dev_sample;
    io.aborted = dev_never_aborted;
    io.progress = NULL;
    end = ram_drive(&st, &io, &head);

    CHECK(!d.killed, "KILLED: limit %llu f0 %llu chunk %llu bg %.0f speed %.1f updates %d avail %d: peak %.0f", limit, f0, chunk, bg, ms_per_mb,
          host_updates, report_available, d.peak);
    /* something else growing by 120 MB/s while the host takes two seconds per sample is a case to survive, not to keep a margin in */
    CHECK(bg > 60.0 || d.peak <= (double)limit - 128.0, "too close: peak %.0f of limit %llu (limit %llu f0 %llu chunk %llu bg %.0f speed %.1f updates %d avail %d)",
          d.peak, limit, limit, f0, chunk, bg, ms_per_mb, host_updates, report_available);
    if (end == RAM_END_REACHED) {
        CHECK(st.got_mb >= target, "reached but took %llu of %llu", st.got_mb, target);
    } else if (end == RAM_END_LIMIT && host_updates) {
        /* stopped at the limit with live numbers: it must have used nearly all the room the margin leaves */
        double left = (double)limit - d.fp;
        double allowed = (double)margin + (double)chunk + 120.0 + bg * (2 * dev_period(&d) / 1000.0 + 1.0);
        CHECK(left <= allowed, "stopped too early: %.0f MB left, allowed %.0f (limit %llu f0 %llu chunk %llu bg %.0f speed %.1f avail %d)", left, allowed, limit,
              f0, chunk, bg, ms_per_mb, report_available);
    } else if (!host_updates) {
        CHECK(end == RAM_END_LIMIT || end == RAM_END_REACHED, "blind run ended with %d", end);
        CHECK(st.got_mb <= st.blind_cap_mb, "blind run took %llu MB, cap %llu", st.got_mb, st.blind_cap_mb);
    } else {
        CHECK(0, "unexpected end %d (limit %llu f0 %llu chunk %llu bg %.0f)", end, limit, f0, chunk, bg);
    }
}

static void sim_all(void)
{
    static const u64 limits[] = { 1536, 2048, 3072, 4096, 5120, 6144, 8150, 10240, 12288 };
    static const u64 starts[] = { 400, 900, 1400, 2200 };
    static const u64 chunks[] = { 32, 64 };
    static const double bgs[] = { 0, 10, 40, 120 };
    static const double speeds[] = { 0.4, 2.5, 9.0 };
    size_t a, b, c, e, f;
    int g;

    for (a = 0; a < sizeof limits / sizeof limits[0]; a++)
        for (b = 0; b < sizeof starts / sizeof starts[0]; b++) {
            if (starts[b] + 1100 > limits[a]) continue;          /* an app that starts nearly at its limit is not a case for a test to survive */
            for (c = 0; c < 2; c++)
                for (e = 0; e < sizeof bgs / sizeof bgs[0]; e++)
                    for (f = 0; f < sizeof speeds / sizeof speeds[0]; f++)
                        for (g = 0; g < 2; g++)
                            sim_one(limits[a], starts[b], chunks[c], bgs[e], speeds[f], 1, g, 99999);
        }
    /* the host that never updates: blind, a small cap */
    sim_one(8150, 1000, 64, 0, 2.0, 0, 1, 99999);
    sim_one(3072, 1200, 32, 30, 2.0, 0, 1, 99999);
    /* a target below the limit is reached */
    sim_one(8150, 1000, 64, 0, 1.0, 1, 1, 2048);
    sim_one(8150, 1000, 64, 20, 1.0, 1, 0, 4096);
}

/* a host that stops updating halfway: the test stops there and does not go on blind */
static int stall_calls;
static int stalling_sample(void *ctx, u64 *avail)
{
    dev *d = (dev *)ctx;
    if (++stall_calls > 2) { d->host_updates = 0; return 0; }
    return dev_sample(ctx, avail);
}

static void stale_case(void)
{
    dev d;
    ram_state st;
    ram_io io;
    int end;

    memset(&d, 0, sizeof d);
    d.limit = 8150;
    d.fp = 1000;
    d.ms_per_mb = 1.0;
    d.host_updates = 1;
    d.report_available = 1;
    dev_step(&d, 0.0, 0.0);
    d.last_seq_wanted = d.seq;
    memset(&st, 0, sizeof st);
    st.target_mb = 99999;
    st.chunk_mb = 64;
    st.margin_mb = ram_margin_mb(d.limit);
    st.base_avail_mb = d.limit - (u64)d.sample_fp;
    st.fresh = 1;
    io.ctx = &d;
    io.take = dev_take;
    io.sample = stalling_sample;
    io.aborted = dev_never_aborted;
    io.progress = NULL;
    end = ram_drive(&st, &io, NULL);
    CHECK(end == RAM_END_STALE, "a host that stops updating ends the run as stale, got %d", end);
    CHECK(!d.killed, "the stalled run was killed (peak %.0f)", d.peak);
}

static int abort_after;
static int abort_when(void *ctx) { (void)ctx; return --abort_after < 0; }
static void abort_case(void)
{
    dev d;
    ram_state st;
    ram_io io;
    memset(&d, 0, sizeof d);
    d.limit = 8150; d.fp = 1000; d.ms_per_mb = 0.1; d.host_updates = 1; d.report_available = 1;
    dev_step(&d, 0.0, 0.0);
    memset(&st, 0, sizeof st);
    st.target_mb = 99999; st.chunk_mb = 64; st.margin_mb = 815; st.base_avail_mb = 7000; st.fresh = 1;
    io.ctx = &d; io.take = dev_take; io.sample = dev_sample; io.aborted = abort_when; io.progress = NULL;
    abort_after = 3;
    CHECK(ram_drive(&st, &io, NULL) == RAM_END_ABORT && st.got_mb == 3 * 64, "abort stops after three pieces, got %llu", st.got_mb);
}

/* a sample that says "0 left" after real ones is a stop, never a blind run */
static int zero_sample(void *ctx, u64 *avail) { (void)ctx; *avail = 0; return 1; }
static void zero_case(void)
{
    dev d;
    ram_state st;
    ram_io io;
    memset(&d, 0, sizeof d);
    d.limit = 8150; d.fp = 1000; d.ms_per_mb = 0.1; d.host_updates = 1; d.report_available = 1;
    memset(&st, 0, sizeof st);
    st.target_mb = 99999; st.chunk_mb = 64; st.margin_mb = 815; st.base_avail_mb = 1800; st.blind_cap_mb = 3000;
    io.ctx = &d; io.take = dev_take; io.sample = zero_sample; io.aborted = dev_never_aborted; io.progress = NULL;
    CHECK(ram_drive(&st, &io, NULL) == RAM_END_LIMIT && st.got_mb < 1100, "an answer of 0 left after a real one stops the run (took %llu)", st.got_mb);
}

/* ------------------------------------------------------------------ the rest */

static void kv_cases(void)
{
    static const char info[] = "format=1\nbuild=602\nversion=0.1.602\nmodel=iPhone18,2\nos=iOS 27.0.1 (24A446)\nram_mb=11695\nlimit_mb=8150\ncores=6\n"
                               "increased_memory=1\nextended_va=0\naddress_map_gb=512\npool_cfg_mb=1152\nswap_mb=12228\r\n";
    static const char live[] = "seq=41\nfootprint_mb=2901\navailable_mb=5249\ncompressed_mb=12\nswap_used_mb=0\npool_total_kb=917504\npool_head_kb=410000\n"
                               "pool_tail_kb=92160\npool_hole_kb=53248\npool_free_kb=12288\npool_virgin_kb=349000\npoolc_total_kb=418816\npoolc_used_kb=88000\n";
    host_status h;
    u64 v;
    const char *p;
    size_t n;

    host_status_clear(&h);
    host_parse_info(info, &h);
    host_parse_live(live, &h);
    CHECK(h.have_info && h.have_live && h.have_pool, "info and live are read");
    CHECK(!strcmp(h.build, "602") && !strcmp(h.model, "iPhone18,2") && !strcmp(h.os, "iOS 27.0.1 (24A446)"), "strings: %s %s %s", h.build, h.model, h.os);
    CHECK(h.ram_mb == 11695 && h.limit_mb == 8150 && h.cores == 6 && h.increased_memory == 1 && h.extended_va == 0 && h.address_map_gb == 512, "numbers");
    CHECK(h.pool_cfg_mb == 1152 && h.swap_mb == 12228, "pool/swap");
    CHECK(h.seq == 41 && h.footprint_mb == 2901 && h.available_mb == 5249 && h.pool_total_kb == 917504 && h.pool_virgin_kb == 349000 && h.poolc_used_kb == 88000, "live");
    host_status_clear(&h);
    host_parse_info("garbage\n", &h);
    host_parse_live("", &h);
    CHECK(!h.have_info && !h.have_live && h.increased_memory == -1, "garbage is no host status");
    CHECK(!kv_u64("a=12x\n", "a", &v) && !kv_u64("a=\n", "a", &v) && !kv_u64("ab=1\n", "a", &v) && kv_u64("x=1\na=7\n", "a", &v) && v == 7, "kv_u64");
    CHECK(kv_find("a=1\r\nb=two \r\n", "b", &p, &n) && n == 3 && !memcmp(p, "two", 3), "trailing spaces and CR are cut");
    CHECK(!kv_find("aa=1\n", "a", &p, &n), "a key is a whole key");
}

static cpu_info fake(unsigned l1c, unsigned l1d, unsigned l7b, unsigned e1c, u64 xcr0)
{
    cpu_info c;
    memset(&c, 0, sizeof c);
    c.max_leaf = 0xd;
    c.max_ext = 0x80000008u;
    c.l1.ecx = l1c;
    c.l1.edx = l1d;
    c.l7.ebx = l7b;
    c.e1.ecx = e1c;
    c.e1.edx = (1u << 29) | (1u << 11) | (1u << 20);
    c.xcr0 = xcr0;
    return c;
}

#define B(n) (1u << (n))

static void cpu_cases(void)
{
    unsigned v2c = B(0) | B(9) | B(13) | B(19) | B(20) | B(23);
    unsigned v3c = v2c | B(12) | B(22) | B(27) | B(28) | B(29);
    unsigned edx = B(23) | B(25) | B(26);
    unsigned v3b = B(3) | B(5) | B(8);
    unsigned v4b = v3b | B(16) | B(17) | B(28) | B(30) | B(31);
    cpu_info c;
    char text[400];

    c = fake(v3c, edx, v3b, B(0) | B(5), 7);
    CHECK(cpu_level(&c) == 3 && cpu_avx_usable(&c) && !cpu_avx512_usable(&c), "an AVX2 machine is v3");
    c = fake(v3c, edx, v3b, B(0) | B(5), 0);
    CHECK(cpu_level(&c) == 2 && !cpu_avx_usable(&c), "AVX that the system does not save is only v2");
    c = fake(v2c, edx, 0, B(0), 0);
    CHECK(cpu_level(&c) == 2, "SSE4.2 machine without AVX is v2");
    c = fake(B(0), edx, 0, B(0), 0);
    CHECK(cpu_level(&c) == 1, "no SSE4.2 is v1");
    c = fake(0, edx & ~B(26), 0, 0, 0);
    CHECK(cpu_level(&c) == 0, "no SSE2 is below v1");
    c = fake(v3c, edx, v4b, B(0) | B(5), 0xE7);
    CHECK(cpu_level(&c) == 4 && cpu_avx512_usable(&c), "AVX-512 with the state saved is v4");
    c = fake(v3c, edx, v4b, B(0) | B(5), 7);
    CHECK(cpu_level(&c) == 3, "AVX-512 without the state saved stays v3");
    c = fake(v3c, edx, v3b, B(0) | B(5), 7);
    c.max_leaf = 4;
    CHECK(!cpu_has(&c, "AVX2") && cpu_level(&c) == 2, "leaf 7 does not exist: no AVX2");
    c = fake(v3c, edx, v3b, B(0) | B(5), 7);
    cpu_feature_text(&c, text, sizeof text, 2, 40);
    CHECK(strstr(text, "AVX2") && strstr(text, "SSE4.2") && !strstr(text, "AVX512F") && text[0] == ' ', "feature text: %s", text);
    {
        char line[64];
        char *nl;
        int ok = 1;
        char *p = text;
        while ((nl = strchr(p, '\n')) || *p) {
            size_t n = nl ? (size_t)(nl - p) : strlen(p);
            if (n > 41) ok = 0;
            if (!nl) break;
            p = nl + 1;
        }
        (void)line;
        CHECK(ok, "feature text wraps at 40 columns: %s", text);
    }
    {
        char tiny[10];
        cpu_feature_text(&c, tiny, sizeof tiny, 2, 40);
        CHECK(strlen(tiny) < sizeof tiny, "a tiny buffer is never overrun");
    }
}

static void misc_cases(void)
{
    unsigned v[4];
    char t[32];

    CHECK(version_parse("14.38.33135.0", v) == 4 && v[0] == 14 && v[1] == 38 && v[2] == 33135, "version_parse");
    CHECK(version_parse("12,0,21005,1", v) == 4 && v[0] == 12 && v[3] == 1, "version_parse with commas");
    CHECK(version_parse("x", v) == 0 && version_parse("", v) == 0, "version_parse of nothing");
    CHECK(!strcmp(vcrt_year_of_version(14), "2015-2022") && !strcmp(vcrt_year_of_version(10), "2010") && !vcrt_year_of_version(13), "years");
    CHECK(VCRT_ROW_COUNT == 6 && !strcmp(vcrt_rows[5].dll_crt, "vcruntime140.dll"), "the table runs from 2005 to 2022");
    CHECK(mb_per_s(100000000ull, 1000.0) == 100.0 && mb_per_s(1, 0.0) == 0.0, "mb_per_s");
    fmt_mb(t, sizeof t, 512);
    CHECK(!strcmp(t, "512 MB"), "fmt_mb small: %s", t);
    fmt_mb(t, sizeof t, 6963);
    CHECK(!strcmp(t, "6.8 GB"), "fmt_mb large: %s", t);
    fmt_kb(t, sizeof t, 917504);
    CHECK(!strcmp(t, "896.0 MB"), "fmt_kb: %s", t);
    CHECK(ram_margin_mb(3072) == 512 && ram_margin_mb(8150) == 815 && ram_margin_mb(20000) == 1024 && ram_margin_mb(0) == 512, "margin");
    CHECK(ram_base_avail(8150, 2900, 5000) == 5000 && ram_base_avail(8150, 2900, 0) == 5250 && ram_base_avail(0, 2900, 0) == 0 &&
          ram_base_avail(2000, 2900, 0) == 0, "base_avail");
    CHECK(!strcmp(verdict_name(V_LIMIT), "LIMIT") && !strcmp(verdict_name(V_FAIL), "FAIL"), "verdict names");
}

int main(void)
{
    kv_cases();
    cpu_cases();
    misc_cases();
    sim_all();
    stale_case();
    abort_case();
    zero_case();
    printf("%d checks, %d failed\n", checks, fails);
    return fails ? 1 : 0;
}
