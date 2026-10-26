// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// fdi_host.h: a stand-in for <fdi.h> and Windows' cabinet.dll for the host check (tests/host/check-bcd-runtimes.py). It declares the
// same types as the real header (the parts cabs.h uses) and implements FDICreate, FDICopy and FDIDestroy over a plain container
// instead of the cabinet format, calling the program's callbacks in the order the real FDI does:
//   open the cabinet, seek to its end and back, read its header,
//   fdintCABINET_INFO, then for each file fdintCOPY_FILE (the callback answers with a handle, 0 to skip the file, -1 to abort),
//   the file's bytes through the write callback in pieces of at most 32 KB, fdintCLOSE_FILE_INFO, and finally close the cabinet.
// What the container is: a real cabinet header (36 bytes: "MSCF", cbCabinet, coffFiles = 36, version 1.3, cFiles) followed by the
// file entries (u32 size, u8 name length, name) and then the files' bytes in the same order. It is not a cabinet and holds no
// compression; the check uses the real cabinet.dll's behaviour only through this order of calls. The real thing is compiled (types
// and calling convention) by tools/build-bcd-runtimes.sh, and runs on the device.

#ifndef BCD_RUNTIMES_FDI_HOST_H
#define BCD_RUNTIMES_FDI_HOST_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define DIAMONDAPI
typedef intptr_t INT_PTR;
typedef unsigned int UINT;
typedef uint32_t ULONG;
typedef int32_t LONG;
typedef int BOOL;
typedef unsigned short USHORT;
typedef void *HFDI;
#define TRUE 1
#define FALSE 0
#define cpuUNKNOWN (-1)

typedef struct { int erfOper; int erfType; BOOL fError; } ERF, *PERF;

typedef enum {
    fdintCABINET_INFO, fdintPARTIAL_FILE, fdintCOPY_FILE, fdintCLOSE_FILE_INFO, fdintNEXT_CABINET, fdintENUMERATE
} FDINOTIFICATIONTYPE;

typedef struct {
    LONG cb;
    char *psz1, *psz2, *psz3;
    void *pv;
    INT_PTR hf;
    USHORT date, time, attribs, setID, iCabinet, iFolder;
    int fdie;
} FDINOTIFICATION, *PFDINOTIFICATION;

typedef void *(DIAMONDAPI *PFNALLOC)(ULONG cb);
typedef void (DIAMONDAPI *PFNFREE)(void *pv);
typedef INT_PTR (DIAMONDAPI *PFNOPEN)(char *pszFile, int oflag, int pmode);
typedef UINT (DIAMONDAPI *PFNREAD)(INT_PTR hf, void *pv, UINT cb);
typedef UINT (DIAMONDAPI *PFNWRITE)(INT_PTR hf, void *pv, UINT cb);
typedef int (DIAMONDAPI *PFNCLOSE)(INT_PTR hf);
typedef LONG (DIAMONDAPI *PFNSEEK)(INT_PTR hf, LONG dist, int seektype);
typedef INT_PTR (DIAMONDAPI *PFNFDINOTIFY)(FDINOTIFICATIONTYPE fdint, PFDINOTIFICATION pfdin);
typedef INT_PTR (DIAMONDAPI *PFNFDIDECRYPT)(void *pfdid);

typedef struct {
    PFNALLOC alloc; PFNFREE free; PFNOPEN open; PFNREAD read; PFNWRITE write; PFNCLOSE close; PFNSEEK seek;
} fdi_host_state;

/* Test switches. */
static long fdi_host_fail_after_bytes = -1;      /* the Nth byte written through a callback handle is where the "copy" stops, as a failing FDI does */
static long fdi_host_written;
static int fdi_host_opens, fdi_host_closes;      /* every cabinet opened is closed */

static HFDI fdi_host_create(PFNALLOC a, PFNFREE f, PFNOPEN o, PFNREAD r, PFNWRITE w, PFNCLOSE c, PFNSEEK s, int cpu, PERF perf)
{
    fdi_host_state *st = (fdi_host_state *)malloc(sizeof *st);
    (void)cpu; (void)perf;
    if (!st) return NULL;
    st->alloc = a; st->free = f; st->open = o; st->read = r; st->write = w; st->close = c; st->seek = s;
    return st;
}

static BOOL fdi_host_destroy(HFDI h)
{
    free(h);
    return TRUE;
}

static BOOL fdi_host_copy(HFDI h, char *cab, char *path, int flags, PFNFDINOTIFY notify, PFNFDIDECRYPT dec, void *user)
{
    fdi_host_state *st = (fdi_host_state *)h;
    char full[512];
    unsigned char head[36];
    INT_PTR hf;
    LONG end;
    uint32_t cb, nfiles, i;
    unsigned char *names_raw = NULL;
    uint32_t *sizes = NULL;
    char (*names)[64] = NULL;
    BOOL ok = FALSE;
    FDINOTIFICATION n;
    (void)flags; (void)dec; (void)user;

    snprintf(full, sizeof full, "%s%s", path, cab);
    hf = st->open(full, 0, 0);
    if (hf == -1) return FALSE;
    fdi_host_opens++;
    end = st->seek(hf, 0, 2);
    if (end < 36 || st->seek(hf, 0, 0) != 0) goto done;
    if (st->read(hf, head, 36) != 36 || memcmp(head, "MSCF", 4) != 0) goto done;
    cb = head[8] | (head[9] << 8) | (head[10] << 16) | ((uint32_t)head[11] << 24);
    nfiles = head[28] | (head[29] << 8);
    if (cb > (uint32_t)end) goto done;
    names_raw = NULL;
    sizes = (uint32_t *)calloc(nfiles + 1, sizeof *sizes);
    names = (char (*)[64])calloc(nfiles + 1, 64);
    if (!sizes || !names) goto done;
    for (i = 0; i < nfiles; i++) {
        unsigned char e[5], nl;
        if (st->read(hf, e, 5) != 5) goto done;
        sizes[i] = e[0] | (e[1] << 8) | (e[2] << 16) | ((uint32_t)e[3] << 24);
        nl = e[4];
        if (nl >= 64 || st->read(hf, names[i], nl) != nl) goto done;
        names[i][nl] = 0;
    }
    memset(&n, 0, sizeof n);
    n.cb = (LONG)cb;
    if (notify(fdintCABINET_INFO, &n) == -1) goto done;
    for (i = 0; i < nfiles; i++) {
        INT_PTR out;
        unsigned char buf[32768];
        uint32_t left = sizes[i];
        memset(&n, 0, sizeof n);
        n.cb = (LONG)sizes[i];
        n.psz1 = names[i];
        out = notify(fdintCOPY_FILE, &n);
        if (out == -1) goto done;
        if (out == 0) {                                     /* skipped: step over its bytes */
            if (st->seek(hf, (LONG)left, 1) == -1) goto done;
            continue;
        }
        while (left) {
            UINT piece = left > sizeof buf ? (UINT)sizeof buf : left;
            if (st->read(hf, buf, piece) != piece) goto done;
            if (fdi_host_fail_after_bytes >= 0 && fdi_host_written + (long)piece > fdi_host_fail_after_bytes) {
                UINT part = (UINT)(fdi_host_fail_after_bytes - fdi_host_written);
                if (part) st->write(out, buf, part);
                fdi_host_written += part;
                goto done;                                  /* a failing FDI stops here and does not close the file */
            }
            if (st->write(out, buf, piece) != piece) goto done;
            fdi_host_written += piece;
            left -= piece;
        }
        memset(&n, 0, sizeof n);
        n.psz1 = names[i];
        n.hf = out;
        if (notify(fdintCLOSE_FILE_INFO, &n) != TRUE) goto done;
    }
    ok = TRUE;
done:
    free(names_raw);
    free(sizes);
    free(names);
    st->close(hf);
    fdi_host_closes++;
    return ok;
}

#endif /* BCD_RUNTIMES_FDI_HOST_H */
