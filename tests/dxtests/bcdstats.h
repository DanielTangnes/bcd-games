// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// bcdstats.h: the pure arithmetic of BCD's test programs (round 602), with no Windows header, so that
// tests/host/check-bcd-tests.py compiles it on the host and checks it against known answers:
//   - frame-time statistics (min / average / max FPS, 1 % low, stutters) and the verdict of the frame-time test;
//   - the nearest display refresh rate to a measured frame interval;
//   - the stereo test tone of the sound test (left only, right only, both);
//   - a colour packed into a DirectDraw / GDI pixel format from its bit masks;
//   - YUV to RGB, and the measurements the video test makes on a decoded picture (the progress bar's length, the
//     colour of the two halves), for the clips tools/gen-video-test-clips.sh makes.

#ifndef BCD_STATS_H
#define BCD_STATS_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ frame times */

typedef struct {
    int n;                       /* frames measured */
    double min_ms, max_ms, avg_ms, median_ms, p99_ms;
    double fps_min, fps_avg, fps_max;   /* from the slowest, the mean and the fastest frame */
    double fps_1pct_low;         /* the rate of the slowest 1 % of the frames (at least one frame) */
    int stutters;                /* frames longer than 1.5 x the median + 2 ms */
} bt_ft_stats_t;

static inline int bt_cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

/* ms: n frame durations in milliseconds (n <= 8192). Returns 0 for no data. */
static inline int bt_ft_stats(const double *ms, int n, bt_ft_stats_t *s)
{
    static double sorted[8192];
    double sum = 0, tail = 0;
    int i, k;

    memset(s, 0, sizeof *s);
    if (n <= 0 || n > 8192) return 0;
    memcpy(sorted, ms, (size_t)n * sizeof(double));
    qsort(sorted, (size_t)n, sizeof(double), bt_cmp_double);
    for (i = 0; i < n; i++) sum += sorted[i];
    s->n = n;
    s->min_ms = sorted[0];
    s->max_ms = sorted[n - 1];
    s->avg_ms = sum / n;
    s->median_ms = (n & 1) ? sorted[n / 2] : 0.5 * (sorted[n / 2 - 1] + sorted[n / 2]);
    s->p99_ms = sorted[(int)((n - 1) * 0.99 + 0.5)];
    s->fps_min = s->max_ms > 0 ? 1000.0 / s->max_ms : 0;
    s->fps_max = s->min_ms > 0 ? 1000.0 / s->min_ms : 0;
    s->fps_avg = s->avg_ms > 0 ? 1000.0 / s->avg_ms : 0;
    k = n / 100;
    if (k < 1) k = 1;
    for (i = n - k; i < n; i++) tail += sorted[i];
    s->fps_1pct_low = tail > 0 ? 1000.0 * k / tail : 0;
    for (i = 0; i < n; i++)
        if (ms[i] > 1.5 * s->median_ms + 2.0) s->stutters++;
    return 1;
}

/* The standard refresh rate nearest to a frame interval, within 6 %; 0 when none is close (an uncapped or irregular loop). */
static inline int bt_refresh_class(double median_ms)
{
    static const int rates[] = { 24, 30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 240 };
    size_t i;
    double hz, best_err = 1e9;
    int best = 0;
    if (median_ms <= 0) return 0;
    hz = 1000.0 / median_ms;
    for (i = 0; i < sizeof rates / sizeof rates[0]; i++) {
        double err = fabs(hz - rates[i]) / rates[i];
        if (err <= 0.06 && err < best_err) { best_err = err; best = rates[i]; }
    }
    return best;
}

/* The frame-time test's verdict: 1 PASS or 0 FAIL, with the reason in `why`. `refresh` is the display's rate (0 unknown),
 * `vsync` whether Present waited for the display. */
static inline int bt_ft_verdict(const bt_ft_stats_t *s, double refresh, int vsync, char *why, size_t cap)
{
    if (s->n < 60) { snprintf(why, cap, "only %d frames", s->n); return 0; }
    if (s->fps_avg < 24.0) { snprintf(why, cap, "slow: %.1f fps on average", s->fps_avg); return 0; }
    if (s->stutters * 20 > s->n) { snprintf(why, cap, "stutter: %d of %d frames (%.1f %%) were more than 1.5x the median", s->stutters, s->n, 100.0 * s->stutters / s->n); return 0; }
    if (vsync && refresh >= 30 && s->fps_avg < 0.8 * refresh) {
        snprintf(why, cap, "does not hold the display's %.0f Hz: %.1f fps on average", refresh, s->fps_avg);
        return 0;
    }
    snprintf(why, cap, "%.1f fps on average, %d stutters in %d frames", s->fps_avg, s->stutters, s->n);
    return 1;
}

/* ------------------------------------------------------------------ the sound test's tone */

/* Three seconds of 16-bit stereo at `rate`: second 1 a 440 Hz tone in the LEFT channel only, second 2 a 660 Hz tone in the
 * RIGHT channel only, second 3 both. Each tone is at 25 % of full scale with 15 ms fades at its edges. Returns the
 * number of frames (3 * rate); `out` holds 2 * 3 * rate samples. */
static inline size_t bt_tone_stereo(int16_t *out, int rate)
{
    size_t seg = (size_t)rate, total = seg * 3, i, fade = (size_t)rate * 15 / 1000;
    const double pi = 3.14159265358979323846;
    for (i = 0; i < total; i++) {
        size_t s = i / seg, at = i % seg;
        double env = 1.0, l = 0, r = 0;
        if (at < fade) env = (double)at / fade;
        else if (seg - at <= fade) env = (double)(seg - at) / fade;
        if (s == 0 || s == 2) l = 0.25 * env * sin(2 * pi * 440.0 * (double)at / rate);
        if (s == 1 || s == 2) r = 0.25 * env * sin(2 * pi * 660.0 * (double)at / rate);
        out[2 * i] = (int16_t)lrint(32767.0 * l);
        out[2 * i + 1] = (int16_t)lrint(32767.0 * r);
    }
    return total;
}

/* The same tone in one channel, for a buffer that is panned: 440 Hz mono, `seconds` long. */
static inline size_t bt_tone_mono(int16_t *out, int rate, int seconds)
{
    size_t total = (size_t)rate * (size_t)seconds, i, fade = (size_t)rate * 15 / 1000;
    const double pi = 3.14159265358979323846;
    for (i = 0; i < total; i++) {
        double env = 1.0;
        if (i < fade) env = (double)i / fade;
        else if (total - i <= fade) env = (double)(total - i) / fade;
        out[i] = (int16_t)lrint(32767.0 * 0.25 * env * sin(2 * pi * 440.0 * (double)i / rate));
    }
    return total;
}

/* ------------------------------------------------------------------ pixel formats */

/* The number of set bits and the lowest set bit of a colour mask. */
static inline void bt_mask_info(uint32_t mask, int *bits, int *shift)
{
    int b = 0, s = 0;
    if (mask) {
        while (!((mask >> s) & 1)) s++;
        while (((mask >> (s + b)) & 1) && s + b < 32) b++;
    }
    *bits = b;
    *shift = s;
}

/* 8-bit r, g, b packed into a pixel of the given masks (a 16-bit 565, a 15-bit 555 or a 32-bit format all work). */
static inline uint32_t bt_pack_rgb(uint32_t rmask, uint32_t gmask, uint32_t bmask, int r, int g, int b)
{
    int rb, rs, gb, gs, bb, bs;
    bt_mask_info(rmask, &rb, &rs);
    bt_mask_info(gmask, &gb, &gs);
    bt_mask_info(bmask, &bb, &bs);
    return (rb ? ((uint32_t)(r >> (8 - rb)) << rs) : 0) | (gb ? ((uint32_t)(g >> (8 - gb)) << gs) : 0) | (bb ? ((uint32_t)(b >> (8 - bb)) << bs) : 0);
}

/* The 8-bit colour a pixel of those masks stands for (low bits replicated), for reading a surface back. */
static inline void bt_unpack_rgb(uint32_t rmask, uint32_t gmask, uint32_t bmask, uint32_t pixel, int *r, int *g, int *b)
{
    int rb, rs, gb, gs, bb, bs;
    uint32_t v;
    bt_mask_info(rmask, &rb, &rs);
    bt_mask_info(gmask, &gb, &gs);
    bt_mask_info(bmask, &bb, &bs);
    v = rb ? (pixel & rmask) >> rs : 0;
    *r = rb ? (int)((v << (8 - rb)) | (v >> (2 * rb - 8 < 0 ? 0 : 2 * rb - 8))) : 0;
    v = gb ? (pixel & gmask) >> gs : 0;
    *g = gb ? (int)((v << (8 - gb)) | (v >> (2 * gb - 8 < 0 ? 0 : 2 * gb - 8))) : 0;
    v = bb ? (pixel & bmask) >> bs : 0;
    *b = bb ? (int)((v << (8 - bb)) | (v >> (2 * bb - 8 < 0 ? 0 : 2 * bb - 8))) : 0;
}

/* ------------------------------------------------------------------ video */

/* The clips (tools/gen-video-test-clips.sh): CLIP_W x CLIP_H, CLIP_N frames at CLIP_FPS, a mono tone at CLIP_RATE.
 * Frame i has a progress bar along the bottom CLIP_BAR rows whose bright part is (i + 1) * CLIP_W / CLIP_N pixels long,
 * a white square that moves, a red left half and a blue right half. */
#define BT_CLIP_W 160
#define BT_CLIP_H 96
#define BT_CLIP_N 30
#define BT_CLIP_FPS 15
#define BT_CLIP_RATE 44100
#define BT_CLIP_BAR 8

static inline int bt_clip_expected_bar(int frame) { return (frame + 1) * BT_CLIP_W / BT_CLIP_N; }

static inline int bt_clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

/* BT.601 limited-range YUV to 8-bit RGB. */
static inline void bt_yuv_to_rgb(int y, int u, int v, int *r, int *g, int *b)
{
    int c = y - 16, d = u - 128, e = v - 128;
    *r = bt_clamp8((298 * c + 409 * e + 128) >> 8);
    *g = bt_clamp8((298 * c - 100 * d - 208 * e + 128) >> 8);
    *b = bt_clamp8((298 * c + 516 * d + 128) >> 8);
}

/* The length of the progress bar in a luma plane (the row in the middle of the bar, bright = above the mid level). The bar
 * is white (luma 235) on near black (luma 35); a pixel counts above 130. */
static inline int bt_bar_length(const uint8_t *luma, int stride, int w, int h)
{
    const uint8_t *row = luma + (size_t)(h - BT_CLIP_BAR / 2) * (size_t)stride;
    int x, n = 0;
    for (x = 0; x < w; x++)
        if (row[x] > 130) n++;
    return n;
}

/* The mean U and V over a block of an NV12 chroma plane (interleaved U, V), block origin and size in chroma samples. */
static inline void bt_nv12_block_uv(const uint8_t *uv, int stride, int x0, int y0, int bw, int bh, int *u, int *v)
{
    long su = 0, sv = 0;
    int x, y;
    for (y = y0; y < y0 + bh; y++)
        for (x = x0; x < x0 + bw; x++) {
            su += uv[(size_t)y * (size_t)stride + 2 * (size_t)x];
            sv += uv[(size_t)y * (size_t)stride + 2 * (size_t)x + 1];
        }
    *u = (int)(su / (bw * bh));
    *v = (int)(sv / (bw * bh));
}

/* 1 when a colour looks red (r clearly above g and b), 2 when it looks blue, 0 otherwise. */
static inline int bt_hue_class(int r, int g, int b)
{
    if (r > g + 50 && r > b + 50) return 1;
    if (b > g + 50 && b > r + 50) return 2;
    return 0;
}

/* ---- decoded pictures to BGRA (the order a Windows 32-bit pixel has in memory), for the window and for the measurements ---- */

static inline void bt_put_yuv(uint8_t *dst, int y, int u, int v)
{
    int r, g, b;
    bt_yuv_to_rgb(y, u, v, &r, &g, &b);
    dst[0] = (uint8_t)b; dst[1] = (uint8_t)g; dst[2] = (uint8_t)r; dst[3] = 255;
}

/* NV12: a Y plane, then interleaved U, V at half size. out: w * h * 4. */
static inline void bt_nv12_to_bgra(const uint8_t *y, int ypitch, const uint8_t *uv, int uvpitch, int w, int h, uint8_t *out)
{
    int row, col;
    for (row = 0; row < h; row++)
        for (col = 0; col < w; col++) {
            const uint8_t *c = uv + (size_t)(row / 2) * (size_t)uvpitch + 2 * (size_t)(col / 2);
            bt_put_yuv(out + ((size_t)row * (size_t)w + (size_t)col) * 4, y[(size_t)row * (size_t)ypitch + (size_t)col], c[0], c[1]);
        }
}

/* I420 (planes Y, U, V) or YV12 (Y, V, U: pass the planes in that order). */
static inline void bt_planar_to_bgra(const uint8_t *y, int ypitch, const uint8_t *u, const uint8_t *v, int cpitch, int w, int h, uint8_t *out)
{
    int row, col;
    for (row = 0; row < h; row++)
        for (col = 0; col < w; col++)
            bt_put_yuv(out + ((size_t)row * (size_t)w + (size_t)col) * 4, y[(size_t)row * (size_t)ypitch + (size_t)col],
                       u[(size_t)(row / 2) * (size_t)cpitch + (size_t)(col / 2)], v[(size_t)(row / 2) * (size_t)cpitch + (size_t)(col / 2)]);
}

/* YUY2: Y0 U Y1 V for two pixels. */
static inline void bt_yuy2_to_bgra(const uint8_t *p, int pitch, int w, int h, uint8_t *out)
{
    int row, col;
    for (row = 0; row < h; row++)
        for (col = 0; col < w; col++) {
            const uint8_t *q = p + (size_t)row * (size_t)pitch + 4 * (size_t)(col / 2);
            bt_put_yuv(out + ((size_t)row * (size_t)w + (size_t)col) * 4, q[(col & 1) ? 2 : 0], q[1], q[3]);
        }
}

/* RGB32 / ARGB32 (B, G, R, x in memory): rows copied; the alpha byte is forced opaque. */
static inline void bt_rgb32_to_bgra(const uint8_t *p, int pitch, int w, int h, uint8_t *out)
{
    int row, col;
    for (row = 0; row < h; row++)
        for (col = 0; col < w; col++) {
            const uint8_t *q = p + (size_t)row * (size_t)pitch + 4 * (size_t)col;
            uint8_t *d = out + ((size_t)row * (size_t)w + (size_t)col) * 4;
            d[0] = q[0]; d[1] = q[1]; d[2] = q[2]; d[3] = 255;
        }
}

/* In a BGRA picture: the length of the bright run (green above 130) along a row, and the hue class of one pixel. */
static inline int bt_bgra_bar_length(const uint8_t *bgra, int w, int row)
{
    int x, n = 0;
    for (x = 0; x < w; x++)
        if (bgra[((size_t)row * (size_t)w + (size_t)x) * 4 + 1] > 130) n++;
    return n;
}

static inline int bt_bgra_hue(const uint8_t *bgra, int w, int x, int y)
{
    const uint8_t *q = bgra + ((size_t)y * (size_t)w + (size_t)x) * 4;
    return bt_hue_class(q[2], q[1], q[0]);
}

#endif /* BCD_STATS_H */
