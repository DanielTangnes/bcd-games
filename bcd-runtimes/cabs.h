// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// cabs.h: takes the DLLs BCD does not carry out of Microsoft's DirectX End-User Runtimes (June 2010).
//
// directx_Jun2010_redist.exe is a self-extractor whose tail is one big cabinet (LZX) of about a hundred and fifty smaller ones, each a
// handful of DLLs for one DirectX release and one processor: Jun2010_d3dx9_43_x86.cab, Aug2009_XACT_x64.cab, ... Running its DXSETUP.exe
// would write Microsoft's copy of every one of them into the Windows folders, over Wine's own builtin versions, which BCD ships and
// tests with each game. So this does not run it. It opens the cabinets with Windows' own cabinet.dll (FDI, which Wine implements,
// LZX included), and writes a DLL only where nothing of that name is there yet:
//   *_x86.cab  ->  C:\windows\syswow64   (the 32-bit folder)
//   *_x64.cab  ->  C:\windows\system32   (the 64-bit folder)
// A name that exists is kept as it is (counted, not listed), so every game keeps the DLLs it runs with today; what is added is what was
// missing (the older XACT engines, XAPOFX1_0, D3DCSX, d3dx10.dll of 2006, the 64-bit XACT engines). Each file is written under a
// ".bcd-part" name and renamed only if the final name is still free, so a copy cut short (the app closed meanwhile) never sits in the
// folder under its real name, and nothing is ever overwritten. Managed DirectX (MDX1: .NET assemblies for the GAC), the setup program,
// the catalogs and the .inf files are skipped.
//
// The program supplies the pieces that touch Windows (the file the cabinet is in, the folders it writes to, the log) through rt_src,
// rt_dest and rt_dx_say; the host check supplies a stand-in for cabinet.dll that reads a simple container and calls the same
// callbacks in the same order, and drives this code on temporary folders.

#ifndef BCD_RUNTIMES_CABS_H
#define BCD_RUNTIMES_CABS_H

#include "core.h"

#ifdef BCD_HOST_TEST
#include "fdi_host.h"
#else
#include <windows.h>
#include <fdi.h>
#endif

/* Where the outer cabinet is read from: bytes [base, base + length) of a file, so that offset 0 of the cabinet is `base`. */
typedef struct {
    int (*read)(void *ctx, u64 offset, void *buf, size_t n);   /* absolute offset in the file; returns the bytes read or -1 */
    void *ctx;
    u64 base, length;
} rt_src;

/* Where DLLs are written. */
typedef struct {
    int (*exists)(void *ctx, const char *path);                              /* 1 when something of that name is there */
    void *(*begin)(void *ctx, const char *final_path);                       /* opens "<final_path>.bcd-part" for writing; NULL on failure */
    int (*write)(void *ctx, void *file, const void *data, size_t n);         /* 0 ok */
    int (*commit)(void *ctx, void *file, const char *final_path);            /* close, rename if final_path is still free: 0 renamed, 1 the name is taken, -1 error */
    void (*abort)(void *ctx, void *file, const char *final_path);            /* close and delete the part file */
    void *ctx;
} rt_dest;

typedef struct {
    char name[56];
    int is64;
} rt_dx_added;

typedef struct {
    int added, kept, failed, skipped_files, cabs_read, cabs_skipped;
    int outer_ok;                      /* the outer cabinet was read to its end */
    rt_dx_added list[160];
    int list_n;
} rt_dx_stats;

/* The three cabinet.dll entry points, looked up by the program (GetProcAddress) or supplied by the host check. */
typedef struct {
    HFDI (*create)(PFNALLOC, PFNFREE, PFNOPEN, PFNREAD, PFNWRITE, PFNCLOSE, PFNSEEK, int, PERF);
    BOOL (*copy)(HFDI, char *, char *, int, PFNFDINOTIFY, PFNFDIDECRYPT, void *);
    BOOL (*destroy)(HFDI);
} rt_fdi_api;

typedef struct {
    const rt_fdi_api *api;
    const rt_src *src;
    rt_dest dest;
    const char *dir_x86;               /* "C:\\windows\\syswow64" */
    const char *dir_x64;               /* "C:\\windows\\system32" */
    void (*say)(void *ctx, const char *line);
    void *say_ctx;
    rt_dx_stats st;
    /* state while reading */
    HFDI outer, inner;
    ERF erf_outer, erf_inner;
    const u8 *cur_mem;                 /* the inner cabinet being read */
    size_t cur_len;
    int cur_kind;
    void *open_file;                   /* the DLL being written, to clean up after a failed copy */
    void *pending_dll;                 /* the rt_vfile of that DLL and of the inner cabinet being collected: freed if FDI never closes them */
    void *pending_mem;
    char open_path[512];
    char open_name[56];                /* the file's name as the cabinet gave it, kept: the close notification is not relied on to repeat it */
    size_t open_expect, open_wrote;
    int open_bad;
} rt_dx;

/* A file the callbacks hand to FDI. */
#define RT_V_OUTER 1
#define RT_V_INNER 2
#define RT_V_SINK_MEM 3
#define RT_V_SINK_DLL 4
typedef struct {
    int kind;
    u64 pos;
    rt_dx *dx;
    u8 *mem;
    size_t len, cap;
    int cab_kind;                      /* for a memory sink: RT_CAB_X86 / RT_CAB_X64 */
} rt_vfile;

#define RT_MAX_INNER_CAB (24u << 20)
#define RT_MAX_DLL (32u << 20)

static rt_dx *rt_g_dx;                  /* the callbacks have no user pointer; one extraction runs at a time */

static void *DIAMONDAPI rt_fdi_alloc(ULONG cb) { return malloc(cb ? cb : 1); }
static void DIAMONDAPI rt_fdi_free(void *p) { free(p); }

static INT_PTR DIAMONDAPI rt_fdi_open(char *name, int oflag, int pmode)
{
    rt_vfile *v;
    (void)oflag; (void)pmode;
    if (!rt_g_dx || !name) return -1;
    if (strcmp(name, "bcd-outer") != 0 && strcmp(name, "bcd-inner") != 0) return -1;
    v = (rt_vfile *)calloc(1, sizeof *v);
    if (!v) return -1;
    v->kind = strcmp(name, "bcd-outer") == 0 ? RT_V_OUTER : RT_V_INNER;
    v->dx = rt_g_dx;
    return (INT_PTR)v;
}

static UINT DIAMONDAPI rt_fdi_read(INT_PTR hf, void *pv, UINT cb)
{
    rt_vfile *v = (rt_vfile *)hf;
    rt_dx *dx = v->dx;

    if (v->kind == RT_V_OUTER) {
        u64 left = dx->src->length > v->pos ? dx->src->length - v->pos : 0;
        int got;
        if (cb > left) cb = (UINT)left;
        if (cb == 0) return 0;
        got = dx->src->read(dx->src->ctx, dx->src->base + v->pos, pv, cb);
        if (got < 0) return (UINT)-1;
        v->pos += (u64)got;
        return (UINT)got;
    }
    if (v->kind == RT_V_INNER) {
        size_t left = dx->cur_len > v->pos ? dx->cur_len - (size_t)v->pos : 0;
        if (cb > left) cb = (UINT)left;
        memcpy(pv, dx->cur_mem + v->pos, cb);
        v->pos += cb;
        return cb;
    }
    return (UINT)-1;
}

static UINT DIAMONDAPI rt_fdi_write(INT_PTR hf, void *pv, UINT cb)
{
    rt_vfile *v = (rt_vfile *)hf;
    rt_dx *dx = v->dx;

    if (v->kind == RT_V_SINK_MEM) {
        if (cb > v->cap - v->len) return (UINT)-1;
        memcpy(v->mem + v->len, pv, cb);
        v->len += cb;
        return cb;
    }
    if (v->kind == RT_V_SINK_DLL) {
        if (dx->open_wrote + cb > dx->open_expect || dx->dest.write(dx->dest.ctx, dx->open_file, pv, cb) != 0) {
            dx->open_bad = 1;
            return (UINT)-1;
        }
        dx->open_wrote += cb;
        return cb;
    }
    return (UINT)-1;
}

static int DIAMONDAPI rt_fdi_close(INT_PTR hf)
{
    rt_vfile *v = (rt_vfile *)hf;
    if (v && (v->kind == RT_V_OUTER || v->kind == RT_V_INNER)) free(v);
    return 0;
}

static LONG DIAMONDAPI rt_fdi_seek(INT_PTR hf, LONG dist, int type)
{
    rt_vfile *v = (rt_vfile *)hf;
    rt_dx *dx = v->dx;
    u64 size, to;

    if (v->kind == RT_V_OUTER) size = dx->src->length;
    else if (v->kind == RT_V_INNER) size = dx->cur_len;
    else return -1;
    if (type == 0) { if (dist < 0) return -1; to = (u64)dist; }                        /* SEEK_SET */
    else if (type == 1) { if (dist < 0 && (u64)(-(long long)dist) > v->pos) return -1; to = v->pos + (u64)(long long)dist; }
    else if (type == 2) { if (dist < 0 && (u64)(-(long long)dist) > size) return -1; to = size + (u64)(long long)dist; }
    else return -1;
    if (to > size) return -1;
    v->pos = to;
    return (LONG)to;
}

static void rt_dx_note(rt_dx *dx, const char *fmt, const char *a, const char *b)
{
    char line[400];
    if (!dx->say) return;
    snprintf(line, sizeof line, fmt, a ? a : "", b ? b : "");
    dx->say(dx->say_ctx, line);
}

/* After a copy that ended in the middle of a file: close and delete the part file, free what FDI never closed. */
static void rt_dx_cleanup_open(rt_dx *dx)
{
    if (dx->open_file) {
        dx->dest.abort(dx->dest.ctx, dx->open_file, dx->open_path);
        dx->open_file = NULL;
    }
    free(dx->pending_dll);
    dx->pending_dll = NULL;
}

static void rt_dx_cleanup_mem(rt_dx *dx)
{
    rt_vfile *v = (rt_vfile *)dx->pending_mem;
    if (v) {
        free(v->mem);
        free(v);
    }
    dx->pending_mem = NULL;
}

/* Notifications of the inner cabinets: a DLL in them is written if its name is free. */
static INT_PTR DIAMONDAPI rt_fdi_notify_inner(FDINOTIFICATIONTYPE t, PFDINOTIFICATION n)
{
    rt_dx *dx = rt_g_dx;
    rt_vfile *v;
    char path[512];
    const char *dir;

    switch (t) {
    case fdintCABINET_INFO:
    case fdintPARTIAL_FILE:
        return 0;
    case fdintNEXT_CABINET:
        return -1;                                           /* a cabinet that continues in another one is not what this is */
    case fdintCOPY_FILE:
        if (!n->psz1 || !rt_dll_name_ok(n->psz1)) { dx->st.skipped_files++; return 0; }
        dir = dx->cur_kind == RT_CAB_X64 ? dx->dir_x64 : dx->dir_x86;
        if (snprintf(path, sizeof path, "%s\\%s", dir, n->psz1) >= (int)sizeof path || !rt_path_below(path, dir)) {
            dx->st.failed++;
            return 0;
        }
        if (dx->dest.exists(dx->dest.ctx, path)) { dx->st.kept++; return 0; }         /* BCD's own file, or one an earlier run added */
        if (n->cb <= 0 || (unsigned long)n->cb > RT_MAX_DLL) { dx->st.failed++; rt_dx_note(dx, "%s: unexpected size, skipped", n->psz1, NULL); return 0; }
        rt_dx_cleanup_open(dx);
        dx->open_file = dx->dest.begin(dx->dest.ctx, path);
        if (!dx->open_file) { dx->st.failed++; rt_dx_note(dx, "%s could not be created", path, NULL); return 0; }
        snprintf(dx->open_path, sizeof dx->open_path, "%s", path);
        snprintf(dx->open_name, sizeof dx->open_name, "%s", n->psz1);
        dx->open_expect = (size_t)n->cb;
        dx->open_wrote = 0;
        dx->open_bad = 0;
        v = (rt_vfile *)calloc(1, sizeof *v);
        if (!v) { rt_dx_cleanup_open(dx); dx->st.failed++; return 0; }
        v->kind = RT_V_SINK_DLL;
        v->dx = dx;
        dx->pending_dll = v;
        return (INT_PTR)v;
    case fdintCLOSE_FILE_INFO:
        v = (rt_vfile *)n->hf;
        if (v && v->kind == RT_V_SINK_DLL) {
            int ok = dx->open_file && !dx->open_bad && dx->open_wrote == dx->open_expect;
            if (ok) {
                int c = dx->dest.commit(dx->dest.ctx, dx->open_file, dx->open_path);
                dx->open_file = NULL;
                if (c == 0) {
                    dx->st.added++;
                    if (dx->st.list_n < (int)(sizeof dx->st.list / sizeof dx->st.list[0])) {
                        rt_dx_added *a = &dx->st.list[dx->st.list_n++];
                        snprintf(a->name, sizeof a->name, "%s", dx->open_name);
                        a->is64 = dx->cur_kind == RT_CAB_X64;
                    }
                } else if (c == 1) {
                    dx->st.kept++;                          /* someone else created the name meanwhile */
                } else {
                    dx->st.failed++;
                    rt_dx_note(dx, "%s could not be put in place", dx->open_path, NULL);
                }
            } else {
                rt_dx_cleanup_open(dx);
                dx->st.failed++;
                rt_dx_note(dx, "%s was cut short; removed", dx->open_name, NULL);
            }
            free(v);
            dx->pending_dll = NULL;
        }
        return 1;
    default:
        return 0;
    }
}

/* One inner cabinet in memory. */
static void rt_dx_inner(rt_dx *dx, const u8 *mem, size_t len, int kind)
{
    dx->cur_mem = mem;
    dx->cur_len = len;
    dx->cur_kind = kind;
    dx->st.cabs_read++;
    if (!dx->api->copy(dx->inner, (char *)"bcd-inner", (char *)"", 0, rt_fdi_notify_inner, NULL, dx)) {
        dx->st.failed++;
        rt_dx_note(dx, "a cabinet could not be read to its end", NULL, NULL);
        rt_dx_cleanup_open(dx);
    }
    dx->cur_mem = NULL;
    dx->cur_len = 0;
}

/* Notifications of the outer cabinet: the wanted inner cabinets are collected in memory, one at a time, and read when complete. */
static INT_PTR DIAMONDAPI rt_fdi_notify_outer(FDINOTIFICATIONTYPE t, PFDINOTIFICATION n)
{
    rt_dx *dx = rt_g_dx;
    rt_vfile *v;
    int kind;

    switch (t) {
    case fdintCABINET_INFO:
    case fdintPARTIAL_FILE:
        return 0;
    case fdintNEXT_CABINET:
        return -1;
    case fdintCOPY_FILE:
        kind = rt_dx_cab_kind(n->psz1);
        if (kind == RT_CAB_SKIP || n->cb <= 0 || (unsigned long)n->cb > RT_MAX_INNER_CAB) { dx->st.cabs_skipped++; return 0; }
        v = (rt_vfile *)calloc(1, sizeof *v);
        if (!v) return -1;
        v->mem = (u8 *)malloc((size_t)n->cb);
        if (!v->mem) { free(v); return -1; }
        v->kind = RT_V_SINK_MEM;
        v->dx = dx;
        v->cap = (size_t)n->cb;
        v->cab_kind = kind;
        dx->pending_mem = v;
        return (INT_PTR)v;
    case fdintCLOSE_FILE_INFO:
        v = (rt_vfile *)n->hf;
        if (v && v->kind == RT_V_SINK_MEM) {
            if (v->len == v->cap) rt_dx_inner(dx, v->mem, v->len, v->cab_kind);
            else { dx->st.failed++; rt_dx_note(dx, "%s is incomplete", n->psz1, NULL); }
            free(v->mem);
            free(v);
            dx->pending_mem = NULL;
        }
        return 1;
    default:
        return 0;
    }
}

/* Reads the outer cabinet and every wanted inner one. Returns 0 when the outer cabinet was read to its end (individual DLLs may still
 * have failed: see the statistics), -1 when it could not be opened or read. */
static int rt_dx_extract(rt_dx *dx)
{
    int rc = -1;

    memset(&dx->st, 0, sizeof dx->st);
    dx->open_file = NULL;
    dx->pending_dll = dx->pending_mem = NULL;
    rt_g_dx = dx;
    dx->outer = dx->api->create(rt_fdi_alloc, rt_fdi_free, rt_fdi_open, rt_fdi_read, rt_fdi_write, rt_fdi_close, rt_fdi_seek, cpuUNKNOWN, &dx->erf_outer);
    dx->inner = dx->api->create(rt_fdi_alloc, rt_fdi_free, rt_fdi_open, rt_fdi_read, rt_fdi_write, rt_fdi_close, rt_fdi_seek, cpuUNKNOWN, &dx->erf_inner);
    if (dx->outer && dx->inner) {
        if (dx->api->copy(dx->outer, (char *)"bcd-outer", (char *)"", 0, rt_fdi_notify_outer, NULL, dx)) {
            dx->st.outer_ok = 1;
            rc = 0;
        }
        rt_dx_cleanup_open(dx);
        rt_dx_cleanup_mem(dx);
    }
    if (dx->outer) dx->api->destroy(dx->outer);
    if (dx->inner) dx->api->destroy(dx->inner);
    dx->outer = dx->inner = NULL;
    rt_g_dx = NULL;
    return rc;
}

/* The offset of the first cabinet in a file's first bytes (an "MSCF" with zero reserved words and version 1.3 whose declared size fits),
 * or -1. `head` is the file's first n bytes, `file_size` its size; *cab_size gets the cabinet's own size. */
static long long rt_find_cab(const u8 *head, size_t n, u64 file_size, u64 *cab_size)
{
    size_t i;
    for (i = 0; i + 36 <= n; i++) {
        if (head[i] == 'M' && head[i + 1] == 'S' && head[i + 2] == 'C' && head[i + 3] == 'F' && rt_rd32(head + i + 4) == 0 &&
            rt_rd32(head + i + 12) == 0 && rt_rd32(head + i + 20) == 0 && head[i + 24] == 3 && head[i + 25] == 1) {
            u64 size = rt_rd32(head + i + 8);
            u64 files_at = rt_rd32(head + i + 16);
            if (size >= 36 && size <= file_size - i && files_at < size) {
                *cab_size = size;
                return (long long)i;
            }
        }
    }
    return -1;
}

#endif /* BCD_RUNTIMES_CABS_H */
