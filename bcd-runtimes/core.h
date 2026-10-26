// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// core.h: the part of BCD's runtimes installer (bcd-runtimes/runtimes.c) that needs no Windows. runtimes.c includes it for the
// program; tests/host/check-bcd-runtimes.py compiles it for the host (clang, ASan/UBSan) and runs core_test.c against known answers.
//
// What the installer does, in one paragraph. A shortcut in the Wine desktop's Start menu ("BCD Runtimes") starts
// bcd-runtimes-x64.exe with the name of a runtime. The program shows what it is about to download (vendor, file, size, where from),
// waits for the person to press the button, downloads the vendor's own file over HTTPS from the one host this table names, checks its
// SHA-256 and its exact size against the values pinned here (a file that differs is deleted and never run), then installs it the
// way its table row says. Nothing is ever shipped in BCD's package: the files come from Microsoft, NVIDIA and openal.org when the
// person asks, as the Visual C++ runtime does (app/Madeira/VCRuntimeDownload.swift is the model: an allow-list of hosts, HTTPS only,
// redirects checked by hand, a size ceiling, the checksum).
//
// Contents: SHA-256, CRC-32, a raw-deflate decoder and a ZIP reader (for oalinst.zip), URL and redirect rules, the table of runtimes,
// name and path rules for what gets written, a path-pattern matcher for "is it installed", and the wording of the result line.
// Everything here works on bytes and strings; the program supplies the files, the network and the processes.

#ifndef BCD_RUNTIMES_CORE_H
#define BCD_RUNTIMES_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-function"      /* a header of small functions; each program uses some of them */
#endif

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

/* ================================================================== SHA-256 */

typedef struct {
    u32 h[8];
    u64 total;       /* bytes taken in */
    u8 buf[64];
    size_t fill;
} rt_sha256;

static const u32 rt_k256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define RT_ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void rt_sha256_block(u32 h[8], const u8 *p)
{
    u32 w[64], a, b, c, d, e, f, g, hh, t1, t2;
    int i;

    for (i = 0; i < 16; i++)
        w[i] = ((u32)p[4 * i] << 24) | ((u32)p[4 * i + 1] << 16) | ((u32)p[4 * i + 2] << 8) | (u32)p[4 * i + 3];
    for (i = 16; i < 64; i++) {
        u32 s0 = RT_ROR(w[i - 15], 7) ^ RT_ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        u32 s1 = RT_ROR(w[i - 2], 17) ^ RT_ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
    for (i = 0; i < 64; i++) {
        t1 = hh + (RT_ROR(e, 6) ^ RT_ROR(e, 11) ^ RT_ROR(e, 25)) + ((e & f) ^ (~e & g)) + rt_k256[i] + w[i];
        t2 = (RT_ROR(a, 2) ^ RT_ROR(a, 13) ^ RT_ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void rt_sha256_init(rt_sha256 *s)
{
    static const u32 iv[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
    memcpy(s->h, iv, sizeof iv);
    s->total = 0;
    s->fill = 0;
}

static void rt_sha256_update(rt_sha256 *s, const void *data, size_t len)
{
    const u8 *p = (const u8 *)data;

    s->total += len;
    if (s->fill) {
        size_t take = 64 - s->fill;
        if (take > len) take = len;
        memcpy(s->buf + s->fill, p, take);
        s->fill += take;
        p += take;
        len -= take;
        if (s->fill < 64) return;
        rt_sha256_block(s->h, s->buf);
        s->fill = 0;
    }
    while (len >= 64) {
        rt_sha256_block(s->h, p);
        p += 64;
        len -= 64;
    }
    if (len) {
        memcpy(s->buf, p, len);
        s->fill = len;
    }
}

static void rt_sha256_final(rt_sha256 *s, u8 out[32])
{
    u64 bits = s->total * 8;
    u8 pad = 0x80;
    int i;

    rt_sha256_update(&*s, &pad, 1);
    pad = 0;
    while (s->fill != 56) rt_sha256_update(s, &pad, 1);
    for (i = 7; i >= 0; i--) {
        u8 b = (u8)(bits >> (8 * i));
        rt_sha256_update(s, &b, 1);
    }
    for (i = 0; i < 8; i++) {
        out[4 * i] = (u8)(s->h[i] >> 24);
        out[4 * i + 1] = (u8)(s->h[i] >> 16);
        out[4 * i + 2] = (u8)(s->h[i] >> 8);
        out[4 * i + 3] = (u8)s->h[i];
    }
}

/* Lower-case hex of n bytes into out (2n + 1 bytes). */
static void rt_hex(const u8 *bytes, size_t n, char *out)
{
    static const char digits[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < n; i++) {
        out[2 * i] = digits[bytes[i] >> 4];
        out[2 * i + 1] = digits[bytes[i] & 15];
    }
    out[2 * n] = 0;
}

/* 1 when `hex` is exactly 64 hex digits spelling the digest `d` (either case), else 0. */
static int rt_sha256_is(const u8 d[32], const char *hex)
{
    char mine[65];
    size_t i;

    if (!hex || strlen(hex) != 64) return 0;
    rt_hex(d, 32, mine);
    for (i = 0; i < 64; i++) {
        char c = hex[i];
        if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
        if (c != mine[i]) return 0;
    }
    return 1;
}

/* ================================================================== CRC-32 (the ZIP one) */

static u32 rt_crc32(u32 crc, const void *data, size_t len)
{
    static u32 table[256];
    static int ready;
    const u8 *p = (const u8 *)data;
    size_t i;

    if (!ready) {
        u32 n, k;
        for (n = 0; n < 256; n++) {
            u32 c = n;
            for (k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        ready = 1;
    }
    crc = ~crc;
    for (i = 0; i < len; i++) crc = table[(crc ^ p[i]) & 255] ^ (crc >> 8);
    return ~crc;
}

/* ================================================================== inflate (RFC 1951) */

/* Decodes raw deflate data of which the decoded size is known: `out` has room for out_len bytes and decoding must end at exactly
 * that size (a ZIP entry says how big it is). Returns 0 on success, otherwise a negative number:
 * -1 input ended early, -2 bad block type, -3 stored block length mismatch, -4 bad code lengths, -5 bad symbol or distance,
 * -6 more output than out_len, -7 output shorter than out_len. `*used` gets the input bytes consumed. */
typedef struct {
    const u8 *in;
    size_t len, pos;
    u32 bits;
    int nbits;
    u8 *out;
    size_t cap, n;
} rt_inf;

typedef struct {
    u16 count[16];
    u16 symbol[288];
} rt_huff;

static int rt_inf_need(rt_inf *s, int need)
{
    while (s->nbits < need) {
        if (s->pos >= s->len) return -1;
        s->bits |= (u32)s->in[s->pos++] << s->nbits;
        s->nbits += 8;
    }
    return 0;
}

static int rt_inf_get(rt_inf *s, int need, u32 *value)
{
    if (need == 0) { *value = 0; return 0; }
    if (rt_inf_need(s, need)) return -1;
    *value = s->bits & ((1u << need) - 1);
    s->bits >>= need;
    s->nbits -= need;
    return 0;
}

/* Builds the decoding tables from code lengths; returns 0 for a complete code, > 0 for an incomplete one, < 0 for an over-subscribed one. */
static int rt_huff_build(rt_huff *h, const u16 *length, int n)
{
    int len, sym, left;
    u16 offs[16];

    for (len = 0; len < 16; len++) h->count[len] = 0;
    for (sym = 0; sym < n; sym++) h->count[length[sym]]++;
    if (h->count[0] == n) return 0;
    left = 1;
    for (len = 1; len < 16; len++) {
        left <<= 1;
        left -= h->count[len];
        if (left < 0) return left;
    }
    offs[1] = 0;
    for (len = 1; len < 15; len++) offs[len + 1] = (u16)(offs[len] + h->count[len]);
    for (sym = 0; sym < n; sym++)
        if (length[sym] != 0) h->symbol[offs[length[sym]]++] = (u16)sym;
    return left;
}

static int rt_huff_decode(rt_inf *s, const rt_huff *h)
{
    int code = 0, first = 0, index = 0, len;

    for (len = 1; len < 16; len++) {
        u32 bit;
        int count;
        if (rt_inf_get(s, 1, &bit)) return -1;
        code |= (int)bit;
        count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    return -5;
}

static const u16 rt_len_base[29] = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
static const u16 rt_len_extra[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
static const u16 rt_dist_base[30] = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                      4097, 6145, 8193, 12289, 16385, 24577 };
static const u16 rt_dist_extra[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

static int rt_inf_codes(rt_inf *s, const rt_huff *lit, const rt_huff *dist)
{
    for (;;) {
        int sym = rt_huff_decode(s, lit);
        if (sym < 0) return sym;
        if (sym < 256) {
            if (s->n >= s->cap) return -6;
            s->out[s->n++] = (u8)sym;
        } else if (sym == 256) {
            return 0;
        } else {
            u32 extra, d;
            size_t len, back, i;
            int ds;
            sym -= 257;
            if (sym >= 29) return -5;
            if (rt_inf_get(s, rt_len_extra[sym], &extra)) return -1;
            len = (size_t)rt_len_base[sym] + extra;
            ds = rt_huff_decode(s, dist);
            if (ds < 0) return ds;
            if (ds >= 30) return -5;
            if (rt_inf_get(s, rt_dist_extra[ds], &d)) return -1;
            back = (size_t)rt_dist_base[ds] + d;
            if (back > s->n) return -5;
            if (len > s->cap - s->n) return -6;
            for (i = 0; i < len; i++, s->n++) s->out[s->n] = s->out[s->n - back];
        }
    }
}

static int rt_inflate(const u8 *in, size_t in_len, u8 *out, size_t out_len, size_t *used)
{
    rt_inf s;
    int last;
    static const u8 order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

    s.in = in; s.len = in_len; s.pos = 0; s.bits = 0; s.nbits = 0; s.out = out; s.cap = out_len; s.n = 0;
    do {
        u32 v;
        int type;
        if (rt_inf_get(&s, 1, &v)) return -1;
        last = (int)v;
        if (rt_inf_get(&s, 2, &v)) return -1;
        type = (int)v;
        if (type == 0) {
            u32 len, nlen;
            s.bits = 0;
            s.nbits = 0;                                    /* stored: drop the rest of the byte */
            if (s.pos + 4 > s.len) return -1;
            len = s.in[s.pos] | ((u32)s.in[s.pos + 1] << 8);
            nlen = s.in[s.pos + 2] | ((u32)s.in[s.pos + 3] << 8);
            s.pos += 4;
            if ((len ^ 0xFFFFu) != nlen) return -3;
            if (len > s.len - s.pos) return -1;
            if (len > s.cap - s.n) return -6;
            memcpy(s.out + s.n, s.in + s.pos, len);
            s.n += len;
            s.pos += len;
        } else if (type == 1) {
            static rt_huff lit, dist;
            static int ready;
            if (!ready) {
                u16 l[288];
                int i;
                for (i = 0; i < 144; i++) l[i] = 8;
                for (; i < 256; i++) l[i] = 9;
                for (; i < 280; i++) l[i] = 7;
                for (; i < 288; i++) l[i] = 8;
                rt_huff_build(&lit, l, 288);
                for (i = 0; i < 30; i++) l[i] = 5;
                rt_huff_build(&dist, l, 30);
                ready = 1;
            }
            {
                int r = rt_inf_codes(&s, &lit, &dist);
                if (r) return r;
            }
        } else if (type == 2) {
            u32 nlen, ndist, ncode;
            u16 lengths[320];
            rt_huff lencode, lit, dist;
            int idx;

            if (rt_inf_get(&s, 5, &nlen) || rt_inf_get(&s, 5, &ndist) || rt_inf_get(&s, 4, &ncode)) return -1;
            nlen += 257;
            ndist += 1;
            ncode += 4;
            if (nlen > 286 || ndist > 30) return -4;
            for (idx = 0; idx < 19; idx++) lengths[idx] = 0;
            for (idx = 0; idx < (int)ncode; idx++) {
                u32 x;
                if (rt_inf_get(&s, 3, &x)) return -1;
                lengths[order[idx]] = (u16)x;
            }
            if (rt_huff_build(&lencode, lengths, 19) != 0) return -4;
            idx = 0;
            while (idx < (int)(nlen + ndist)) {
                int sym = rt_huff_decode(&s, &lencode);
                if (sym < 0) return sym;
                if (sym < 16) {
                    lengths[idx++] = (u16)sym;
                } else {
                    u32 rep, x;
                    u16 prev = 0;
                    if (sym == 16) {
                        if (idx == 0) return -4;
                        prev = lengths[idx - 1];
                        if (rt_inf_get(&s, 2, &x)) return -1;
                        rep = 3 + x;
                    } else if (sym == 17) {
                        if (rt_inf_get(&s, 3, &x)) return -1;
                        rep = 3 + x;
                    } else {
                        if (rt_inf_get(&s, 7, &x)) return -1;
                        rep = 11 + x;
                    }
                    if (idx + (int)rep > (int)(nlen + ndist)) return -4;
                    while (rep--) lengths[idx++] = prev;
                }
            }
            if (lengths[256] == 0) return -4;                /* no end-of-block code */
            {
                int e = rt_huff_build(&lit, lengths, (int)nlen);
                if (e < 0 || (e > 0 && (int)nlen != lit.count[0] + lit.count[1])) return -4;
                e = rt_huff_build(&dist, lengths + nlen, (int)ndist);
                if (e < 0 || (e > 0 && (int)ndist != dist.count[0] + dist.count[1])) return -4;
            }
            {
                int r = rt_inf_codes(&s, &lit, &dist);
                if (r) return r;
            }
        } else {
            return -2;
        }
    } while (!last);
    if (used) *used = s.pos;
    return s.n == s.cap ? 0 : -7;
}

/* ================================================================== ZIP */

typedef struct {
    u32 method;       /* 0 stored, 8 deflate */
    u32 crc;
    u64 csize, usize;
    u64 data_off;     /* where the entry's data starts in the file */
} rt_zip_entry;

static u32 rt_rd16(const u8 *p) { return (u32)p[0] | ((u32)p[1] << 8); }
static u32 rt_rd32(const u8 *p) { return rt_rd16(p) | (rt_rd16(p + 2) << 16); }

static int rt_ieq(const char *a, size_t alen, const char *b)
{
    size_t i;
    if (strlen(b) != alen) return 0;
    for (i = 0; i < alen; i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return 0;
    }
    return 1;
}

/* Finds the entry called `name` (compared without regard to case, as stored: no folder part is added or removed) and checks every
 * offset and size it will use. Returns 0 and fills *e; -1 when the file is not a ZIP that this reader understands (ZIP64, encryption,
 * a method other than stored/deflate, an offset outside the file), -2 when the name is not there. */
static int rt_zip_find(const u8 *zip, size_t len, const char *name, rt_zip_entry *e)
{
    size_t eocd, lowest, cd_off, cd_size, p, i, entries;
    int found = 0;

    if (len < 22) return -1;
    lowest = len > 65557 ? len - 65557 : 0;                /* the end-of-central-directory record is in the last 64 KB + 22 bytes */
    for (eocd = len - 22;; eocd--) {
        if (rt_rd32(zip + eocd) == 0x06054b50u) { found = 1; break; }
        if (eocd == lowest) break;
    }
    if (!found) return -1;
    entries = rt_rd16(zip + eocd + 10);
    cd_size = rt_rd32(zip + eocd + 12);
    cd_off = rt_rd32(zip + eocd + 16);
    if (entries == 0xFFFF || cd_size == 0xFFFFFFFFu || cd_off == 0xFFFFFFFFu) return -1;     /* ZIP64 */
    if (cd_off > len || cd_size > len - cd_off) return -1;
    p = cd_off;
    for (i = 0; i < entries; i++) {
        size_t nlen, xlen, clen, lho;
        u32 flags, method;
        if (p + 46 > cd_off + cd_size || rt_rd32(zip + p) != 0x02014b50u) return -1;
        flags = rt_rd16(zip + p + 8);
        method = rt_rd16(zip + p + 10);
        nlen = rt_rd16(zip + p + 28);
        xlen = rt_rd16(zip + p + 30);
        clen = rt_rd16(zip + p + 32);
        lho = rt_rd32(zip + p + 42);
        if (p + 46 + nlen + xlen + clen > cd_off + cd_size) return -1;
        if (rt_ieq((const char *)zip + p + 46, nlen, name)) {
            u64 csize = rt_rd32(zip + p + 20), usize = rt_rd32(zip + p + 24);
            size_t lnlen, lxlen;
            if ((flags & 1) || (method != 0 && method != 8) || csize == 0xFFFFFFFFu || usize == 0xFFFFFFFFu) return -1;
            if (lho > len || len - lho < 30 || rt_rd32(zip + lho) != 0x04034b50u) return -1;
            lnlen = rt_rd16(zip + lho + 26);
            lxlen = rt_rd16(zip + lho + 28);
            if ((u64)lho + 30 + lnlen + lxlen > len) return -1;
            e->method = method;
            e->crc = rt_rd32(zip + p + 16);
            e->csize = csize;
            e->usize = usize;
            e->data_off = (u64)lho + 30 + lnlen + lxlen;
            if (e->data_off > len || e->csize > len - e->data_off) return -1;
            if (method == 0 && csize != usize) return -1;
            return 0;
        }
        p += 46 + nlen + xlen + clen;
    }
    return -2;
}

/* Unpacks the entry into out[0, e->usize) (the caller allocated usize bytes), checking its size and CRC-32. 0 on success, negative otherwise. */
static int rt_zip_extract(const u8 *zip, size_t len, const rt_zip_entry *e, u8 *out)
{
    int r;
    (void)len;
    if (e->method == 0) {
        memcpy(out, zip + e->data_off, (size_t)e->usize);
    } else {
        r = rt_inflate(zip + e->data_off, (size_t)e->csize, out, (size_t)e->usize, NULL);
        if (r) return r;
    }
    return rt_crc32(0, out, (size_t)e->usize) == e->crc ? 0 : -8;
}

/* ================================================================== URLs and redirects */

typedef struct {
    char host[128];
    char path[1024];     /* with its query; starts with / */
} rt_url;

static int rt_host_char_ok(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
}

/* "https://host/path?query" only: no other scheme, no user name or password, no port but 443, a plain host name (letters, digits, dots,
 * hyphens), no control character or space anywhere, no fragment. Returns 1 and fills `out` (the host in lower case), else 0. */
static int rt_url_parse(const char *url, rt_url *out)
{
    const char *p, *host, *end;
    size_t n, i;

    if (!url) return 0;
    for (p = url; *p; p++)
        if ((unsigned char)*p <= 32 || (unsigned char)*p >= 127 || *p == '#' || *p == '\\') return 0;
    if (strncmp(url, "https://", 8) != 0) return 0;
    host = url + 8;
    end = host + strcspn(host, "/?");
    n = (size_t)(end - host);
    if (n >= 4 && host[n - 4] == ':' ) {                /* ":443" is the default port spelled out; any other port is refused */
        if (strncmp(host + n - 4, ":443", 4) != 0) return 0;
        n -= 4;
    } else if (memchr(host, ':', n) || memchr(host, '@', n)) {
        return 0;
    }
    if (n == 0 || n >= sizeof out->host) return 0;
    if (host[0] == '.' || host[0] == '-' || host[n - 1] == '-') return 0;
    for (i = 0; i < n; i++) {
        if (!rt_host_char_ok(host[i])) return 0;
        if (host[i] == '.' && i + 1 < n && host[i + 1] == '.') return 0;
        out->host[i] = (host[i] >= 'A' && host[i] <= 'Z') ? (char)(host[i] - 'A' + 'a') : host[i];
    }
    out->host[n] = 0;
    if (*end == 0) {
        strcpy(out->path, "/");
    } else {
        if (*end == '?') {
            if (strlen(end) + 2 > sizeof out->path) return 0;
            out->path[0] = '/';
            strcpy(out->path + 1, end);
        } else {
            if (strlen(end) + 1 > sizeof out->path) return 0;
            strcpy(out->path, end);
        }
    }
    return 1;
}

/* Whether `host` (any case) is one of the allowed hosts (NULL-ended list), exactly. */
static int rt_host_allowed(const char *host, const char *const *allowed)
{
    size_t i;
    for (i = 0; allowed && allowed[i]; i++)
        if (rt_ieq(host, strlen(host), allowed[i])) return 1;
    return 0;
}

/* Whether a reference starts with a scheme ("https:", "http:", "ftp:", "javascript:", "mailto:"): letters, digits, '+', '-' or '.' up to a
 * ':' that comes before any '/', '?' or '#'. Such a reference is never a relative path. */
static int rt_has_scheme(const char *s)
{
    size_t i;
    if (!((s[0] >= 'a' && s[0] <= 'z') || (s[0] >= 'A' && s[0] <= 'Z'))) return 0;
    for (i = 1; s[i]; i++) {
        char c = s[i];
        if (c == ':') return 1;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.')) return 0;
    }
    return 0;
}

/* Where a redirect (a "Location" header) leads. `base` is the URL that answered. An absolute https URL, a protocol-relative one
 * (//host/...), an absolute path (/x) and a relative path (x/y) are understood; http:, ftp: and anything else is a refusal, and so is a
 * target on a host that is not in the allow-list. Returns 1 and fills `out`, else 0 with `*why` pointing at a short reason. */
static int rt_redirect(const rt_url *base, const char *location, const char *const *allowed, rt_url *out, const char **why)
{
    char full[1200];
    const char *r = "the redirect is not understood";

    if (!location || !*location) { r = "the redirect has no address"; goto no; }
    if (strncmp(location, "//", 2) == 0) {
        if (strlen(location) + 7 > sizeof full) goto no;
        strcpy(full, "https:");
        strcat(full, location);
    } else if (location[0] == '/') {
        if (strlen(base->host) + strlen(location) + 9 > sizeof full) goto no;
        snprintf(full, sizeof full, "https://%s%s", base->host, location);
    } else if (rt_has_scheme(location)) {
        if (strncmp(location, "https://", 8) != 0) { r = "the redirect leaves HTTPS"; goto no; }
        if (strlen(location) + 1 > sizeof full) goto no;
        strcpy(full, location);
    } else {                                              /* relative to the folder of the path that answered */
        char dir[1024];
        char *slash;
        size_t q = strcspn(base->path, "?");
        if (q >= sizeof dir) goto no;
        memcpy(dir, base->path, q);
        dir[q] = 0;
        slash = strrchr(dir, '/');
        if (slash) slash[1] = 0;
        if (strlen(base->host) + strlen(dir) + strlen(location) + 9 > sizeof full) goto no;
        snprintf(full, sizeof full, "https://%s%s%s", base->host, dir, location);
    }
    if (!rt_url_parse(full, out)) { r = "the redirect address is not a plain HTTPS address"; goto no; }
    if (!rt_host_allowed(out->host, allowed)) { r = "the redirect leaves the vendor's download host"; goto no; }
    return 1;
no:
    if (why) *why = r;
    return 0;
}

/* ================================================================== the runtimes */

typedef enum {
    RT_KIND_MSI = 1,      /* msiexec /i file /qn */
    RT_KIND_ZIP_EXE,      /* a ZIP with one installer program, started with a silent switch */
    RT_KIND_PHYSX,        /* NVIDIA's 7-Zip self-extractor: unpacked with BCD's 7z.exe, installed from NVIDIA's own manifest */
    RT_KIND_DX2010,       /* the DirectX end-user runtime: only the files BCD does not provide are taken out of its cabinets */
} rt_kind;

typedef struct {
    const char *id;            /* the argument of the program and the name of its marker file */
    const char *menu;          /* the Start menu entry */
    const char *title;         /* what the window calls it */
    const char *vendor;
    const char *what;          /* one sentence for the window */
    const char *licence;       /* where the vendor's terms are */
    const char *undo;          /* one sentence: how to take it out again */
    const char *file;          /* the file name it is saved under */
    const char *url;
    const char *const *hosts;  /* every host the download may touch, redirects included */
    const char *sha256;
    u64 size;                  /* exactly this many bytes */
    unsigned need_mb;          /* free space asked for before it starts */
    rt_kind kind;
    const char *const *check;  /* NULL-ended path patterns that exist when it is installed (see rt_path_match) */
} rt_runtime;

static const char *const rt_hosts_ms[] = { "download.microsoft.com", NULL };
static const char *const rt_hosts_openal[] = { "www.openal.org", NULL };
static const char *const rt_hosts_nvidia[] = { "us.download.nvidia.com", NULL };

/* A pattern is a Windows path in which one path part may be "*" (any one folder) and alternatives are separated by "|"; the pattern
 * is satisfied when at least one alternative names an existing file. */
static const char *const rt_check_xna[] = {
    "C:\\windows\\Microsoft.NET\\assembly\\GAC_32\\Microsoft.Xna.Framework\\*\\Microsoft.Xna.Framework.dll"
        "|C:\\windows\\Microsoft.NET\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework\\*\\Microsoft.Xna.Framework.dll"
        "|C:\\windows\\assembly\\GAC_32\\Microsoft.Xna.Framework\\*\\Microsoft.Xna.Framework.dll"
        "|C:\\windows\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework\\*\\Microsoft.Xna.Framework.dll",
    "C:\\windows\\Microsoft.NET\\assembly\\GAC_32\\Microsoft.Xna.Framework.Game\\*\\Microsoft.Xna.Framework.Game.dll"
        "|C:\\windows\\Microsoft.NET\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework.Game\\*\\Microsoft.Xna.Framework.Game.dll"
        "|C:\\windows\\assembly\\GAC_32\\Microsoft.Xna.Framework.Game\\*\\Microsoft.Xna.Framework.Game.dll"
        "|C:\\windows\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework.Game\\*\\Microsoft.Xna.Framework.Game.dll",
    "C:\\windows\\Microsoft.NET\\assembly\\GAC_32\\Microsoft.Xna.Framework.Graphics\\*\\Microsoft.Xna.Framework.Graphics.dll"
        "|C:\\windows\\Microsoft.NET\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework.Graphics\\*\\Microsoft.Xna.Framework.Graphics.dll"
        "|C:\\windows\\assembly\\GAC_32\\Microsoft.Xna.Framework.Graphics\\*\\Microsoft.Xna.Framework.Graphics.dll"
        "|C:\\windows\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework.Graphics\\*\\Microsoft.Xna.Framework.Graphics.dll",
    NULL,
};
static const char *const rt_check_physx[] = {
    "C:\\Program Files (x86)\\NVIDIA Corporation\\PhysX\\Common\\PhysXLoader.dll",
    "C:\\Program Files (x86)\\NVIDIA Corporation\\PhysX\\Common\\PhysXDevice.dll",
    "C:\\Program Files (x86)\\NVIDIA Corporation\\PhysX\\Engine\\v2.8.3\\PhysXCore.dll",
    NULL,
};
static const char *const rt_check_openal[] = {
    "C:\\windows\\syswow64\\OpenAL32.dll",
    "C:\\windows\\system32\\OpenAL32.dll",
    NULL,
};
static const char *const rt_check_dx[] = {
    NULL,        /* the DirectX files that were added are listed in the marker file; see runtimes.c (dx_installed) */
};

static const rt_runtime rt_table[] = {
    { "xna", "XNA Framework 4.0", "Microsoft XNA Framework Redistributable 4.0", "Microsoft",
      "The runtime of games built with Microsoft's XNA Framework (many indie games from 2008 to 2013). It needs Wine Mono: install that in BCD's Settings (.NET Framework) first.",
      "https://www.microsoft.com/en-us/download/details.aspx?id=20914",
      "Start > BCD Tools > Uninstall a program removes it again.",
      "xnafx40_redist.msi", "https://download.microsoft.com/download/A/C/2/AC2C903B-E6E8-42C2-9FD7-BEBAC362A930/xnafx40_redist.msi",
      rt_hosts_ms, "47260420773a20443fb1e38a89b7f39c5237a80a842de598e6c8f7f90a3bbd6d", 7054848u, 60, RT_KIND_MSI, rt_check_xna },
    { "physx", "PhysX (legacy)", "NVIDIA PhysX System Software 9.21.0713", "NVIDIA",
      "The older NVIDIA PhysX that games from about 2007 to 2013 expect to find in Windows.",
      "https://www.nvidia.com/en-us/drivers/physx/physx-9-21-0713-legacy-driver/",
      "BCD puts the files in place itself (no entry in Uninstall a program): delete the PhysX folder under C:\\Program Files (x86)\\NVIDIA Corporation to take it out.",
      "PhysX_9.21.0713_SystemSoftware.exe", "https://us.download.nvidia.com/Windows/9.21.0713/PhysX_9.21.0713_SystemSoftware.exe",
      rt_hosts_nvidia, "26d62c5c347c15cb27c3be92bf10706113511b48b28aecc09f61ee58b3b62778", 27152680u, 260, RT_KIND_PHYSX, rt_check_physx },
    { "openal", "OpenAL", "OpenAL installer (Creative Technology)", "Creative Technology / openal.org",
      "OpenAL32.dll for the games that expect OpenAL to be installed in Windows (the software version; sound goes through DirectSound).",
      "https://www.openal.org/",
      "Start > BCD Tools > Uninstall a program removes it again.",
      "oalinst.zip", "https://www.openal.org/downloads/oalinst.zip",
      rt_hosts_openal, "d165bcb7628fd950d14847585468cc11943b2a1da92a59a839d397c68f9d4b06", 590434u, 20, RT_KIND_ZIP_EXE, rt_check_openal },
    { "dx2010", "DirectX June 2010", "DirectX End-User Runtimes (June 2010)", "Microsoft",
      "Adds the older DirectX 9, 10 and 11 files that BCD does not carry (XACT audio 2.x and 3.x, XAPOFX, D3DCSX, the 64-bit XACT engines). "
      "Files BCD already provides are left as they are.",
      "https://www.microsoft.com/en-us/download/details.aspx?id=8109",
      "The files it adds are listed in C:\\ProgramData\\BCD\\Runtimes\\dx2010.txt; deleting them takes it out again.",
      "directx_Jun2010_redist.exe", "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
      rt_hosts_ms, "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b", 100275120u, 250, RT_KIND_DX2010, rt_check_dx },
};
#define RT_COUNT (sizeof rt_table / sizeof rt_table[0])

static const rt_runtime *rt_find(const char *id)
{
    size_t i;
    for (i = 0; id && i < RT_COUNT; i++)
        if (rt_ieq(id, strlen(id), rt_table[i].id)) return &rt_table[i];
    return NULL;
}

/* ================================================================== what may be written */

/* A plain DLL file name from inside a cabinet: letters, digits, '_', '.', '-', ending in .dll, at most 48 characters, no path part. */
static int rt_dll_name_ok(const char *name)
{
    size_t n = name ? strlen(name) : 0, i;

    if (n < 5 || n > 48) return 0;
    if (!rt_ieq(name + n - 4, 4, ".dll")) return 0;
    for (i = 0; i < n; i++) {
        char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')) return 0;
    }
    return name[0] != '.' && strstr(name, "..") == NULL;
}

/* The cabinets of the DirectX end-user runtime that are read: <Release>_<what>_x86.cab and ..._x64.cab. Managed DirectX (MDX1: .NET
 * assemblies that need the GAC), the setup program's own files and the update stub are not DLLs for the system folders and are skipped.
 * Returns 1 for a 32-bit cabinet, 2 for a 64-bit one, 0 for the rest. */
#define RT_CAB_SKIP 0
#define RT_CAB_X86 1
#define RT_CAB_X64 2
static int rt_dx_cab_kind(const char *name)
{
    size_t n = name ? strlen(name) : 0, i;
    char lower[96];

    if (n < 9 || n >= sizeof lower) return RT_CAB_SKIP;
    for (i = 0; i < n; i++) {
        char c = name[i];
        if ((c >= 'A' && c <= 'Z')) c = (char)(c - 'A' + 'a');
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')) return RT_CAB_SKIP;
        lower[i] = c;
    }
    lower[n] = 0;
    if (strstr(lower, "mdx1") || strstr(lower, "archive") || strstr(lower, "dsetup") || strstr(lower, "dxsetup") || strstr(lower, "dxupdate"))
        return RT_CAB_SKIP;
    if (n > 8 && strcmp(lower + n - 8, "_x86.cab") == 0) return RT_CAB_X86;
    if (n > 8 && strcmp(lower + n - 8, "_x64.cab") == 0) return RT_CAB_X64;
    return RT_CAB_SKIP;
}

/* A path may be written only below these folders (case-insensitive prefix, backslashes) and must not climb out of them. */
static int rt_path_below(const char *path, const char *folder)
{
    size_t fl = strlen(folder);

    if (strlen(path) <= fl + 1 || !rt_ieq(path, fl, folder) || path[fl] != '\\') return 0;
    return strstr(path + fl, "\\..") == NULL && strstr(path + fl, "..\\") == NULL && strstr(path, "/") == NULL;
}

/* ================================================================== path patterns */

/* The file system the matcher asks. exists(path): 1 when a file or folder of that name exists. list(dir, i, name, cap): the i-th entry
 * of a folder (0, 1, ...) or 0 when there are no more. */
typedef struct {
    int (*exists)(void *ctx, const char *path);
    int (*list)(void *ctx, const char *dir, int index, char *name, size_t cap);
    void *ctx;
} rt_fs;

static int rt_match_one(const rt_fs *fs, const char *pat, size_t len)
{
    char buf[512];
    const char *star;

    if (len == 0 || len >= sizeof buf) return 0;
    memcpy(buf, pat, len);
    buf[len] = 0;
    star = strstr(buf, "\\*\\");
    if (!star) return fs->exists(fs->ctx, buf);
    {
        char dir[512], name[256], full[800];
        int i;
        size_t dl = (size_t)(star - buf);
        memcpy(dir, buf, dl);
        dir[dl] = 0;
        for (i = 0; fs->list(fs->ctx, dir, i, name, sizeof name); i++) {
            if (strchr(name, '\\') || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) continue;
            if (snprintf(full, sizeof full, "%s\\%s%s", dir, name, star + 2) >= (int)sizeof full) continue;
            if (fs->exists(fs->ctx, full)) return 1;
        }
    }
    return 0;
}

/* 1 when any alternative of the pattern names an existing file. */
static int rt_path_match(const rt_fs *fs, const char *pattern)
{
    const char *p = pattern;

    while (*p) {
        size_t n = strcspn(p, "|");
        if (rt_match_one(fs, p, n)) return 1;
        p += n;
        if (*p == '|') p++;
    }
    return 0;
}

/* How many of the runtime's check patterns are satisfied; *total gets how many there are. */
static int rt_check_count(const rt_fs *fs, const rt_runtime *r, int *total)
{
    int have = 0, n = 0;
    const char *const *c;

    for (c = r->check; c && *c; c++) {
        n++;
        if (rt_path_match(fs, *c)) have++;
    }
    if (total) *total = n;
    return have;
}

/* ================================================================== wording */

#define RT_PASS 1
#define RT_WARN 2
#define RT_FAIL 3
#define RT_SKIP 4

static const char *rt_verdict_name(int v)
{
    return v == RT_PASS ? "PASS" : v == RT_WARN ? "WARN" : v == RT_SKIP ? "SKIP" : "FAIL";
}

/* The one line that ends every run: "RESULT <id>: <verdict> - <text> (<n> failed)". "failed" is in it on purpose: the engine's
 * [guest-log] mirror copies a program's log lines into the session log only when they hold words like it, and this line must get through
 * even when the session mirrors only those. */
static void rt_result_line(char *out, size_t cap, const char *id, int verdict, int failed, const char *text)
{
    snprintf(out, cap, "RESULT %s: %s - %s (%d failed)", id, rt_verdict_name(verdict), text, failed);
}

/* "95.6 MB", "712 KB", "1.5 GB". */
static void rt_size_text(u64 bytes, char *out, size_t cap)
{
    if (bytes >= (u64)1 << 30) snprintf(out, cap, "%.1f GB", (double)bytes / (double)((u64)1 << 30));
    else if (bytes >= (u64)1 << 20) snprintf(out, cap, "%.1f MB", (double)bytes / (double)((u64)1 << 20));
    else if (bytes >= 1024) snprintf(out, cap, "%.0f KB", (double)bytes / 1024.0);
    else snprintf(out, cap, "%u bytes", (unsigned)bytes);
}

/* Progress is written to the log in tenths: the tenth a download has reached (0 to 10), so that the caller writes a line when the number
 * changes (at most 11 lines for a download whatever its size). 0 when the total is not known. */
static int rt_tenth(u64 received, u64 total)
{
    if (total == 0) return 0;
    return received >= total ? 10 : (int)((received * 10) / total);
}

/* What msiexec's exit status means: 0 done, 3010 done (restart asked), 1641 done (restart started), 1638 another version is there
 * already (that is "installed"). Everything else is a failure. */
static int rt_msi_exit_ok(unsigned long code)
{
    return code == 0 || code == 3010 || code == 1641 || code == 1638;
}

#endif /* BCD_RUNTIMES_CORE_H */
