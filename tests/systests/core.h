// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// core.h: the part of BCD's system tests (systest.c) that needs no Windows. Plain C, no operating system calls, so
// tests/host/check-systests.py compiles it on the Mac and runs core_test.c against it. What is here:
//   - the key=value text the app and the engine write into the prefix (C:\ProgramData\BCD\host-info.txt and
//     host-live.txt, app/Madeira/BCDHostStatus.c and build/ntdll-unix/ios_host_status.h) and how it is read;
//   - the RAM test's planner: how much more it may take before iOS would close the app (ram_next);
//   - the processor features from CPUID leaves, and which x86-64 level they add up to;
//   - the Visual C++ runtime table and version helpers;
//   - small arithmetic (MB/s, GB text).

#ifndef BCD_SYSTEST_CORE_H
#define BCD_SYSTEST_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef unsigned long long u64;

/* ------------------------------------------------------------------ key=value text */

/* The value of `key` (a whole line "key=value", at the start of a line) in `text`: its start and length, or 0. */
static int kv_find(const char *text, const char *key, const char **val, size_t *len)
{
    size_t klen = strlen(key);
    const char *p = text;

    if (!text || !*key) return 0;
    while (*p) {
        const char *eol = strchr(p, '\n');
        size_t line = eol ? (size_t)(eol - p) : strlen(p);
        if (line > klen && !strncmp(p, key, klen) && p[klen] == '=') {
            size_t n = line - klen - 1;
            while (n && (p[klen + n] == '\r' || p[klen + n] == ' ')) n--;
            *val = p + klen + 1;
            *len = n;
            return 1;
        }
        if (!eol) break;
        p = eol + 1;
    }
    return 0;
}

/* A decimal number; 1 when `key` is there and the whole value is digits. */
static int kv_u64(const char *text, const char *key, u64 *out)
{
    const char *v;
    size_t n, i;
    u64 r = 0;

    if (!kv_find(text, key, &v, &n) || n == 0 || n > 19) return 0;
    for (i = 0; i < n; i++) {
        if (v[i] < '0' || v[i] > '9') return 0;
        r = r * 10 + (u64)(v[i] - '0');
    }
    *out = r;
    return 1;
}

static int kv_str(const char *text, const char *key, char *out, size_t cap)
{
    const char *v;
    size_t n;

    if (!cap) return 0;
    out[0] = 0;
    if (!kv_find(text, key, &v, &n)) return 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, v, n);
    out[n] = 0;
    return 1;
}

/* ------------------------------------------------------------------ what the app and the engine say */

typedef struct {
    int have_info;              /* host-info.txt was there (written once at the session's start by the app) */
    int have_live;              /* host-live.txt was there (rewritten by the engine every second or so) */
    char build[24], version[24], model[32], os[64];
    u64 ram_mb, limit_mb, cores;
    int increased_memory, extended_va;      /* 1, 0, or -1 when unknown */
    u64 address_map_gb;
    u64 pool_cfg_mb;            /* the pool size the configuration asked for, 0 = the default */
    u64 swap_mb;                /* the swap tier's file cap, 0 = off */
    /* live */
    u64 seq, footprint_mb, available_mb, compressed_mb;
    u64 pool_total_kb, pool_head_kb, pool_tail_kb, pool_hole_kb, pool_free_kb, pool_virgin_kb;
    u64 poolc_total_kb, poolc_used_kb;
    u64 swap_used_mb;
    int have_pool;              /* the live file carries the pool figures */
} host_status;

static void host_status_clear(host_status *h)
{
    memset(h, 0, sizeof *h);
    h->increased_memory = h->extended_va = -1;
}

static void host_parse_info(const char *text, host_status *h)
{
    u64 v;

    h->have_info = text && kv_find(text, "format", &(const char *){ 0 }, &(size_t){ 0 });
    if (!text) return;
    kv_str(text, "build", h->build, sizeof h->build);
    kv_str(text, "version", h->version, sizeof h->version);
    kv_str(text, "model", h->model, sizeof h->model);
    kv_str(text, "os", h->os, sizeof h->os);
    if (kv_u64(text, "ram_mb", &v)) h->ram_mb = v;
    if (kv_u64(text, "limit_mb", &v)) h->limit_mb = v;
    if (kv_u64(text, "cores", &v)) h->cores = v;
    if (kv_u64(text, "increased_memory", &v)) h->increased_memory = v ? 1 : 0;
    if (kv_u64(text, "extended_va", &v)) h->extended_va = v ? 1 : 0;
    if (kv_u64(text, "address_map_gb", &v)) h->address_map_gb = v;
    if (kv_u64(text, "pool_cfg_mb", &v)) h->pool_cfg_mb = v;
    if (kv_u64(text, "swap_mb", &v)) h->swap_mb = v;
}

static void host_parse_live(const char *text, host_status *h)
{
    u64 v;

    h->have_live = text && kv_find(text, "seq", &(const char *){ 0 }, &(size_t){ 0 });
    if (!text) return;
    if (kv_u64(text, "seq", &v)) h->seq = v;
    if (kv_u64(text, "footprint_mb", &v)) h->footprint_mb = v;
    if (kv_u64(text, "available_mb", &v)) h->available_mb = v;
    if (kv_u64(text, "compressed_mb", &v)) h->compressed_mb = v;
    if (kv_u64(text, "swap_used_mb", &v)) h->swap_used_mb = v;
    h->have_pool = kv_u64(text, "pool_total_kb", &v);
    if (h->have_pool) {
        h->pool_total_kb = v;
        if (kv_u64(text, "pool_head_kb", &v)) h->pool_head_kb = v;
        if (kv_u64(text, "pool_tail_kb", &v)) h->pool_tail_kb = v;
        if (kv_u64(text, "pool_hole_kb", &v)) h->pool_hole_kb = v;
        if (kv_u64(text, "pool_free_kb", &v)) h->pool_free_kb = v;
        if (kv_u64(text, "pool_virgin_kb", &v)) h->pool_virgin_kb = v;
        if (kv_u64(text, "poolc_total_kb", &v)) h->poolc_total_kb = v;
        if (kv_u64(text, "poolc_used_kb", &v)) h->poolc_used_kb = v;
    }
}

/* ------------------------------------------------------------------ the RAM test's planner */

/* The RAM test takes memory in chunks and must stop BEFORE iOS closes the app. What it knows:
 *   limit_mb      the engine's measurement of the app's memory limit (host-info.txt), 0 when unknown
 *   a sample      footprint_mb and available_mb from host-live.txt: what iOS charges the app now, and what it says
 *                 is left (os_proc_available_memory; 0 when iOS gave no usable number)
 *   its own use   got_mb, the memory the test holds
 * The headroom is what is left minus a margin kept for BCD itself. A sample is only exact for the moment it was taken:
 * the test keeps the sample and subtracts what it has taken since (never more than it is, so the estimate is on the safe
 * side), and asks for a fresh sample (the engine writes one about every 250 ms above 2.4 GB, every 2 s below) when the
 * estimate gets close to the margin, and after every gigabyte. With no usable number at all the test is "blind" and
 * stays under blind_cap_mb. */
typedef struct {
    u64 target_mb;              /* what was asked for */
    u64 chunk_mb;               /* the next piece */
    u64 margin_mb;              /* kept free */
    u64 base_avail_mb;          /* what was left at the sample, 0 = no usable sample */
    u64 got_mb;                 /* held now */
    u64 got_at_sample_mb;       /* held when the sample was taken */
    u64 blind_cap_mb;           /* the most to take without any sample */
    int fresh;                  /* the sample was taken after the last piece was touched */
} ram_state;

enum { RAM_GO = 0, RAM_WAIT_SAMPLE = 1, RAM_REACHED = 2, RAM_STOP_LIMIT = 3 };

/* The margin: a tenth of the limit, at least 512 MB and at most 1 GB (so a 3 GB limit keeps 512 MB, an 8 GB limit 819 MB). */
static u64 ram_margin_mb(u64 limit_mb)
{
    u64 m = limit_mb / 10;
    if (m < 512) m = 512;
    if (m > 1024) m = 1024;
    return m;
}

/* What is left according to the newest sample: iOS's own number when it gave one, else the limit minus the footprint. */
static u64 ram_base_avail(u64 limit_mb, u64 footprint_mb, u64 available_mb)
{
    if (available_mb) return available_mb;
    if (limit_mb && footprint_mb && limit_mb > footprint_mb) return limit_mb - footprint_mb;
    return 0;
}

/* The decision for the next piece. `*head_mb` (may be NULL) gets the headroom the decision used. */
static int ram_next(const ram_state *s, u64 *head_mb)
{
    u64 est, head, since;

    if (s->got_mb >= s->target_mb) return RAM_REACHED;
    if (!s->base_avail_mb) {                                     /* blind */
        head = s->blind_cap_mb > s->got_mb ? s->blind_cap_mb - s->got_mb : 0;
        if (head_mb) *head_mb = head;
        return head >= s->chunk_mb ? RAM_GO : RAM_STOP_LIMIT;
    }
    since = s->got_mb > s->got_at_sample_mb ? s->got_mb - s->got_at_sample_mb : 0;
    est = s->base_avail_mb > since ? s->base_avail_mb - since : 0;
    head = est > s->margin_mb ? est - s->margin_mb : 0;
    if (head_mb) *head_mb = head;
    if (head < s->chunk_mb) return s->fresh ? RAM_STOP_LIMIT : RAM_WAIT_SAMPLE;
    /* look again first when the limit is near, when 256 MB have gone since the last look while less than 3 GB are left,
     * and in any case after every gigabyte (something else may be growing too) */
    if (!s->fresh && (head < 768 + s->chunk_mb || since >= 1024 || (since >= 256 && est < 3072 + s->margin_mb))) return RAM_WAIT_SAMPLE;
    return RAM_GO;
}

/* How the loop gets at the system: the Windows program fills these in, and so does core_test.c with a simulated device, so the
 * very loop that runs on the phone is the one the host check runs against thousands of made-up devices. */
typedef struct {
    void *ctx;
    int (*take)(void *ctx, u64 chunk_mb);                /* allocate and touch one piece; 0 when Windows refused it */
    int (*sample)(void *ctx, u64 *base_avail_mb);        /* wait for a sample taken after the last piece; 0 on a timeout */
    int (*aborted)(void *ctx);                           /* the window was closed */
    void (*progress)(void *ctx, u64 got_mb);
} ram_io;

enum { RAM_END_REACHED = 0, RAM_END_LIMIT = 1, RAM_END_ALLOC_FAIL = 2, RAM_END_ABORT = 3, RAM_END_STALE = 4 };

static int ram_drive(ram_state *st, const ram_io *io, u64 *head_out)
{
    int stale = 0;
    int had_sample = st->base_avail_mb != 0;

    for (;;) {
        u64 head = 0;
        int d;

        if (io->aborted && io->aborted(io->ctx)) return RAM_END_ABORT;
        d = ram_next(st, &head);
        if (head_out) *head_out = head;
        if (d == RAM_REACHED) return RAM_END_REACHED;
        if (d == RAM_STOP_LIMIT) return RAM_END_LIMIT;
        if (d == RAM_WAIT_SAMPLE) {
            u64 avail = 0;
            if (io->sample(io->ctx, &avail)) {
                if (had_sample && avail == 0) return RAM_END_LIMIT;      /* "nothing left" and "no number" look alike: stop */
                st->base_avail_mb = avail;
                st->got_at_sample_mb = st->got_mb;
                stale = 0;
            } else if (++stale >= 2)
                return RAM_END_STALE;
            st->fresh = 1;
            continue;
        }
        if (!io->take(io->ctx, st->chunk_mb)) return RAM_END_ALLOC_FAIL;
        st->got_mb += st->chunk_mb;
        st->fresh = 0;
        if (io->progress) io->progress(io->ctx, st->got_mb);
    }
}

/* ------------------------------------------------------------------ the processor */

typedef struct { unsigned eax, ebx, ecx, edx; } cpuid_regs;

typedef struct {
    unsigned max_leaf, max_ext;
    char vendor[13], brand[49];
    cpuid_regs l1, l7, l7_1, e1;       /* leaf 1; leaf 7 sub-leaf 0 and 1; leaf 0x80000001 */
    u64 xcr0;                           /* XGETBV(0), 0 when OSXSAVE is not set */
} cpu_info;

enum { R_EAX, R_EBX, R_ECX, R_EDX };
/* which leaf: the four views in cpu_info */
typedef struct { const char *name; int leaf; int reg; int bit; } cpu_feat;
enum { L_1, L_7, L_71, L_E1 };

static const cpu_feat cpu_feats[] = {
    { "MMX", L_1, R_EDX, 23 }, { "SSE", L_1, R_EDX, 25 }, { "SSE2", L_1, R_EDX, 26 },
    { "SSE3", L_1, R_ECX, 0 }, { "SSSE3", L_1, R_ECX, 9 }, { "SSE4.1", L_1, R_ECX, 19 }, { "SSE4.2", L_1, R_ECX, 20 },
    { "POPCNT", L_1, R_ECX, 23 }, { "CX16", L_1, R_ECX, 13 }, { "MOVBE", L_1, R_ECX, 22 }, { "PCLMUL", L_1, R_ECX, 1 },
    { "AES", L_1, R_ECX, 25 }, { "FMA", L_1, R_ECX, 12 }, { "F16C", L_1, R_ECX, 29 }, { "RDRAND", L_1, R_ECX, 30 },
    { "XSAVE", L_1, R_ECX, 26 }, { "OSXSAVE", L_1, R_ECX, 27 }, { "AVX", L_1, R_ECX, 28 },
    { "BMI1", L_7, R_EBX, 3 }, { "AVX2", L_7, R_EBX, 5 }, { "BMI2", L_7, R_EBX, 8 }, { "ERMS", L_7, R_EBX, 9 },
    { "RDSEED", L_7, R_EBX, 18 }, { "ADX", L_7, R_EBX, 19 }, { "SHA", L_7, R_EBX, 29 },
    { "AVX512F", L_7, R_EBX, 16 }, { "AVX512DQ", L_7, R_EBX, 17 }, { "AVX512CD", L_7, R_EBX, 28 },
    { "AVX512BW", L_7, R_EBX, 30 }, { "AVX512VL", L_7, R_EBX, 31 }, { "AVX-VNNI", L_71, R_EAX, 4 },
    { "LAHF", L_E1, R_ECX, 0 }, { "LZCNT", L_E1, R_ECX, 5 }, { "PREFETCHW", L_E1, R_ECX, 8 },
    { "SYSCALL", L_E1, R_EDX, 11 }, { "NX", L_E1, R_EDX, 20 }, { "RDTSCP", L_E1, R_EDX, 27 }, { "LONGMODE", L_E1, R_EDX, 29 },
};
#define CPU_FEAT_COUNT (sizeof cpu_feats / sizeof cpu_feats[0])

static unsigned cpu_reg(const cpuid_regs *r, int reg)
{
    return reg == R_EAX ? r->eax : reg == R_EBX ? r->ebx : reg == R_ECX ? r->ecx : r->edx;
}

static int cpu_has(const cpu_info *c, const char *name)
{
    size_t i;
    for (i = 0; i < CPU_FEAT_COUNT; i++) {
        const cpu_feat *f = &cpu_feats[i];
        const cpuid_regs *r;
        if (strcmp(f->name, name)) continue;
        r = f->leaf == L_1 ? &c->l1 : f->leaf == L_7 ? &c->l7 : f->leaf == L_71 ? &c->l7_1 : &c->e1;
        if (f->leaf == L_7 && c->max_leaf < 7) return 0;
        if (f->leaf == L_71 && c->max_leaf < 7) return 0;
        if (f->leaf == L_E1 && c->max_ext < 0x80000001u) return 0;
        return (cpu_reg(r, f->reg) >> f->bit) & 1u;
    }
    return 0;
}

/* The operating system saves the YMM state (XCR0 bits 1 and 2): AVX and AVX2 can be used only then. */
static int cpu_avx_usable(const cpu_info *c) { return cpu_has(c, "OSXSAVE") && cpu_has(c, "AVX") && (c->xcr0 & 6u) == 6u; }
/* ... and the opmask and ZMM state (bits 5 to 7) for AVX-512. */
static int cpu_avx512_usable(const cpu_info *c) { return cpu_avx_usable(c) && cpu_has(c, "AVX512F") && (c->xcr0 & 0xE6u) == 0xE6u; }

/* x86-64 microarchitecture levels (the psABI's): 0 below v1 (no SSE2), 1, 2, 3, 4. */
static int cpu_level(const cpu_info *c)
{
    static const char *const v1[] = { "SSE", "SSE2", "LONGMODE", NULL };
    static const char *const v2[] = { "CX16", "LAHF", "POPCNT", "SSE3", "SSE4.1", "SSE4.2", "SSSE3", NULL };
    static const char *const v3[] = { "BMI1", "BMI2", "F16C", "FMA", "LZCNT", "MOVBE", "AVX2", NULL };
    static const char *const v4[] = { "AVX512F", "AVX512BW", "AVX512CD", "AVX512DQ", "AVX512VL", NULL };
    const char *const *sets[4] = { v1, v2, v3, v4 };
    int level = 0, k, i;

    for (k = 0; k < 4; k++) {
        for (i = 0; sets[k][i]; i++)
            if (!cpu_has(c, sets[k][i])) return level;
        if (k == 2 && !cpu_avx_usable(c)) return level;
        if (k == 3 && !cpu_avx512_usable(c)) return level;
        level = k + 1;
    }
    return level;
}

/* "SSE SSE2 ..." of the features that are set, wrapped at `width` columns with `indent` spaces; returns the length. */
static size_t cpu_feature_text(const cpu_info *c, char *out, size_t cap, int indent, int width)
{
    size_t i, n = 0;
    int col = indent;

    if (!cap) return 0;
    out[0] = 0;
    for (i = 0; i < CPU_FEAT_COUNT; i++) {
        size_t len;
        if (!cpu_has(c, cpu_feats[i].name)) continue;
        len = strlen(cpu_feats[i].name);
        if (col + (int)len + 1 > width && col > indent) {
            if (n + 1 + (size_t)indent + 1 >= cap) break;
            out[n++] = '\n';
            memset(out + n, ' ', (size_t)indent);
            n += (size_t)indent;
            col = indent;
        } else if (n == 0 && indent) {
            if (n + (size_t)indent + 1 >= cap) break;
            memset(out + n, ' ', (size_t)indent);
            n += (size_t)indent;
        }
        if (n + len + 2 >= cap) break;
        memcpy(out + n, cpu_feats[i].name, len);
        n += len;
        out[n++] = ' ';
        col += (int)len + 1;
        out[n] = 0;
    }
    while (n && out[n - 1] == ' ') out[--n] = 0;
    return n;
}

/* ------------------------------------------------------------------ Visual C++ runtimes */

/* One row of the Visual C++ check: the Redistributable's year, the DLLs a game imports from it, and the registry key the
 * Redistributable's installer sets (below HKLM\SOFTWARE\Microsoft, for the architecture's view). */
typedef struct {
    const char *year;           /* "2005" ... "2015-2022" */
    const char *dll_crt;        /* the C runtime, e.g. msvcr100.dll */
    const char *dll_cpp;        /* the C++ library, e.g. msvcp100.dll, or NULL */
    const char *regkey_x64;     /* SOFTWARE\Microsoft\... key that holds "Installed" (and "Version") for x64, or NULL */
    const char *regkey_x86;     /* ... for x86 */
} vcrt_row;

static const vcrt_row vcrt_rows[] = {
    { "2005",      "msvcr80.dll",  "msvcp80.dll",  NULL, NULL },
    { "2008",      "msvcr90.dll",  "msvcp90.dll",  NULL, NULL },
    { "2010",      "msvcr100.dll", "msvcp100.dll", "VisualStudio\\10.0\\VC\\VCRedist\\x64", "VisualStudio\\10.0\\VC\\VCRedist\\x86" },
    { "2012",      "msvcr110.dll", "msvcp110.dll", "VisualStudio\\11.0\\VC\\Runtimes\\x64", "VisualStudio\\11.0\\VC\\Runtimes\\x86" },
    { "2013",      "msvcr120.dll", "msvcp120.dll", "VisualStudio\\12.0\\VC\\Runtimes\\x64", "VisualStudio\\12.0\\VC\\Runtimes\\x86" },
    { "2015-2022", "vcruntime140.dll", "msvcp140.dll", "VisualStudio\\14.0\\VC\\Runtimes\\x64", "VisualStudio\\14.0\\VC\\Runtimes\\x86" },
};
#define VCRT_ROW_COUNT (sizeof vcrt_rows / sizeof vcrt_rows[0])

/* "14.38.33135.0" -> 14, 38, 33135, 0. Returns how many numbers were read (0 for none). */
static int version_parse(const char *s, unsigned out[4])
{
    int n = 0;
    out[0] = out[1] = out[2] = out[3] = 0;
    while (*s && n < 4) {
        unsigned v = 0;
        int digits = 0;
        while (*s >= '0' && *s <= '9') { v = v * 10 + (unsigned)(*s - '0'); s++; digits++; if (digits > 9) return n; }
        if (!digits) break;
        out[n++] = v;
        if (*s == '.' || *s == ',') s++; else break;
    }
    return n;
}

/* The Visual C++ year a file version belongs to: 8.x is 2005, 9.x 2008, 10.x 2010, 11.x 2012, 12.x 2013, 14.x 2015-2022. */
static const char *vcrt_year_of_version(unsigned major)
{
    switch (major) {
    case 8: return "2005";
    case 9: return "2008";
    case 10: return "2010";
    case 11: return "2012";
    case 12: return "2013";
    case 14: return "2015-2022";
    default: return NULL;
    }
}

/* ------------------------------------------------------------------ numbers as text */

/* Bytes and milliseconds as MB per second (decimal MB, as storage makers count); 0 when no time passed. */
static double mb_per_s(u64 bytes, double ms)
{
    return ms > 0.0 ? ((double)bytes / 1e6) / (ms / 1e3) : 0.0;
}

/* "6.9 GB" / "512 MB": MB with one decimal GB from 1024 MB up. */
static void fmt_mb(char *out, size_t cap, u64 mb)
{
    if (mb >= 1024) snprintf(out, cap, "%.1f GB", (double)mb / 1024.0);
    else snprintf(out, cap, "%llu MB", mb);
}

static void fmt_kb(char *out, size_t cap, u64 kb)
{
    if (kb >= 1024 * 1024) snprintf(out, cap, "%.2f GB", (double)kb / (1024.0 * 1024.0));
    else if (kb >= 1024) snprintf(out, cap, "%.1f MB", (double)kb / 1024.0);
    else snprintf(out, cap, "%llu KB", kb);
}

/* ------------------------------------------------------------------ verdicts */

enum { V_PASS = 0, V_LIMIT = 1, V_WARN = 2, V_FAIL = 3, V_SKIP = 4 };

static const char *verdict_name(int v)
{
    return v == V_PASS ? "PASS" : v == V_LIMIT ? "LIMIT" : v == V_WARN ? "WARN" : v == V_FAIL ? "FAIL" : "SKIP";
}

#endif /* BCD_SYSTEST_CORE_H */
