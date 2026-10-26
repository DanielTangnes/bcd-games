// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's video test (round 602): Media Foundation playing two short clips that BCD made itself (tools/gen-video-test-clips.sh:
// a synthetic picture and a sine wave, no third-party media, 18 KB and 39 KB, carried inside this program as C arrays):
//
//   test.mp4  H.264 Baseline video and AAC-LC audio in an MP4 file, 160x96, 30 frames at 15 fps, 2.0 s, 44100 Hz mono
//   test.wmv  Windows Media Video 8 (wmv2) and Windows Media Audio 2 in an ASF file, the same picture and tone
//
// Each clip is written to the temp folder and opened with MFCreateSourceReaderFromURL, the way games play their cutscenes.
// The test asks the source reader for a raw video type (NV12, then YUY2, RGB32, I420, YV12: the first one it accepts) and
// for float or 16-bit PCM audio, reads every sample, and checks the pictures by what is in them: frame i of the clip has
// a progress bar (i + 1) * 160 / 30 pixels long along the bottom, a red left half and a blue right half, so a decoder that
// drops frames, shows them out of order, swaps colours or turns the picture upside down is caught with the numbers. The
// pictures are shown in the window at their own pace. Audio is checked by the number of samples and the level of the tone,
// not played (the sound test plays).
//
// BCD's Media Foundation decoders: MP4/H.264/AAC works in 32-bit sessions (VideoToolbox and AudioToolbox behind winegstreamer,
// docs/MEDIA.md); a 64-bit process needs env.MADEIRA_WG_64BIT = 1, and WMV/ASF needs that plus
// env.MADEIRA_OPTIN_DLLS = mfasfsrcsnk,wmvdecod,wmadmod (the Resident Evil 2 and 7 lines). A FAIL here with those not set is
// the state of the engine, not a broken test; the hint line says so.

#define COBJMACROS
#include "bcdtest.h"
#include "bcdstats.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include "video_clips.h"

typedef HRESULT (WINAPI *startup_fn)(ULONG, DWORD);
typedef HRESULT (WINAPI *shutdown_fn)(void);
typedef HRESULT (WINAPI *createtype_fn)(IMFMediaType **);
typedef HRESULT (WINAPI *createreader_fn)(LPCWSTR, IMFAttributes *, IMFSourceReader **);

static createtype_fn p_create_type;
static createreader_fn p_create_reader;

typedef struct {
    const char *name, *ext, *hint;
    const unsigned char *data;
    size_t size;
} clip_t;

static const clip_t clips[] = {
    { "MP4 (H.264 + AAC)", ".mp4",
      "H.264 and AAC come from VideoToolbox/AudioToolbox through winegstreamer; 32-bit sessions have it, a 64-bit process needs env.MADEIRA_WG_64BIT = 1",
      clip_mp4, sizeof clip_mp4 },
    { "WMV (WMV8 + WMA2 in ASF)", ".wmv",
      "WMV in ASF needs env.MADEIRA_WG_64BIT = 1 and env.MADEIRA_OPTIN_DLLS = mfasfsrcsnk,wmvdecod,wmadmod (64-bit only today)",
      clip_wmv, sizeof clip_wmv },
};

/* The picture shown in the window. */
static uint8_t g_pic[BT_CLIP_W * BT_CLIP_H * 4];
static int g_pic_valid;
static char g_caption[120];
static char g_clip_line[2][100];   /* per clip: pictures and verdict, for the RESULT line */

static void paint_hook(bt_panel *p, HDC dc, int w, int h)
{
    BITMAPINFO bi;
    RECT cap = { 2 * BT_CLIP_W + 24, 8, w - 8, h };

    (void)p;
    memset(&bi, 0, sizeof bi);
    bi.bmiHeader.biSize = sizeof bi.bmiHeader;
    bi.bmiHeader.biWidth = BT_CLIP_W;
    bi.bmiHeader.biHeight = -BT_CLIP_H;   /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    if (g_pic_valid) {
        SetStretchBltMode(dc, COLORONCOLOR);
        StretchDIBits(dc, 8, 8, 2 * BT_CLIP_W, 2 * BT_CLIP_H, 0, 0, BT_CLIP_W, BT_CLIP_H, g_pic, &bi, DIB_RGB_COLORS, SRCCOPY);
    } else {
        RECT box = { 8, 8, 8 + 2 * BT_CLIP_W, 8 + 2 * BT_CLIP_H };
        HBRUSH b = CreateSolidBrush(RGB(40, 44, 58));
        FillRect(dc, &box, b);
        DeleteObject(b);
    }
    SetTextColor(dc, RGB(204, 208, 218));
    DrawTextA(dc, g_caption, -1, &cap, DT_LEFT | DT_NOPREFIX | DT_WORDBREAK);
    (void)h;
}

static const char *subtype_name(const GUID *g, char *buf, size_t cap)
{
    if (IsEqualGUID(g, &MFVideoFormat_NV12)) return "NV12";
    if (IsEqualGUID(g, &MFVideoFormat_YUY2)) return "YUY2";
    if (IsEqualGUID(g, &MFVideoFormat_RGB32)) return "RGB32";
    if (IsEqualGUID(g, &MFVideoFormat_ARGB32)) return "ARGB32";
    if (IsEqualGUID(g, &MFVideoFormat_I420)) return "I420";
    if (IsEqualGUID(g, &MFVideoFormat_IYUV)) return "IYUV";
    if (IsEqualGUID(g, &MFVideoFormat_YV12)) return "YV12";
    if (IsEqualGUID(g, &MFAudioFormat_PCM)) return "PCM";
    if (IsEqualGUID(g, &MFAudioFormat_Float)) return "Float";
    {   /* a FourCC subtype: {xxxxxxxx-0000-0010-8000-00AA00389B71} */
        char c[5];
        int i, printable = 1;
        for (i = 0; i < 4; i++) {
            c[i] = (char)(g->Data1 >> (8 * i));
            if (c[i] < 0x20 || c[i] > 0x7e) printable = 0;
        }
        c[4] = 0;
        if (printable) snprintf(buf, cap, "%s", c);
        else snprintf(buf, cap, "{%08lx-...}", (unsigned long)g->Data1);
    }
    return buf;
}

static void type_size_rate(IMFMediaType *t, UINT32 *w, UINT32 *h, UINT32 *num, UINT32 *den)
{
    UINT64 v = 0;
    *w = *h = *num = *den = 0;
    if (SUCCEEDED(IMFAttributes_GetUINT64((IMFAttributes *)t, &MF_MT_FRAME_SIZE, &v))) { *w = (UINT32)(v >> 32); *h = (UINT32)v; }
    if (SUCCEEDED(IMFAttributes_GetUINT64((IMFAttributes *)t, &MF_MT_FRAME_RATE, &v))) { *num = (UINT32)(v >> 32); *den = (UINT32)v; }
}

/* Asks the reader for the first of `subtypes` it accepts as the output of `stream`; returns its index or -1. */
static int choose_output(IMFSourceReader *rd, DWORD stream, const GUID *major, const GUID *const *subtypes, int n, bt_panel *pn, const char *clip)
{
    int i;
    for (i = 0; i < n; i++) {
        IMFMediaType *mt = NULL;
        HRESULT hr = p_create_type(&mt);
        char nb[24];
        if (FAILED(hr) || !mt) return -1;
        IMFAttributes_SetGUID((IMFAttributes *)mt, &MF_MT_MAJOR_TYPE, major);
        IMFAttributes_SetGUID((IMFAttributes *)mt, &MF_MT_SUBTYPE, subtypes[i]);
        hr = IMFSourceReader_SetCurrentMediaType(rd, stream, NULL, mt);
        IMFMediaType_Release(mt);
        bt_note(pn, SUCCEEDED(hr) ? BT_INFO : BT_WARN, "  %s: output %s -> %s", clip, subtype_name(subtypes[i], nb, sizeof nb), bt_hr(hr));
        if (SUCCEEDED(hr)) return i;
    }
    return -1;
}

typedef struct {
    int frames, bars_ok, order_breaks, flipped, short_buffers;
    int bar_first, bar_last;
    int hue_left, hue_right;
    LONGLONG ts_first, ts_last;
    int bars[64];
} video_stats;

/* One decoded picture: converted to BGRA, measured, shown. */
static void take_frame(IMFSample *sample, const GUID *sub, UINT32 w, UINT32 h, LONG stride_attr, video_stats *vs, int shown)
{
    IMFMediaBuffer *buf = NULL;
    IMF2DBuffer *b2 = NULL;
    BYTE *data = NULL;
    LONG pitch = 0;
    DWORD cur = 0, max = 0;
    int locked2d = 0, ok = 0;
    uint8_t *pic = g_pic;
    static uint8_t scratch[BT_CLIP_W * BT_CLIP_H * 4];

    if (w != BT_CLIP_W || h != BT_CLIP_H) return;
    if (FAILED(IMFSample_ConvertToContiguousBuffer(sample, &buf)) || !buf) return;
    if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &IID_IMF2DBuffer, (void **)&b2)) && b2) {
        if (SUCCEEDED(IMF2DBuffer_Lock2D(b2, &data, &pitch))) locked2d = 1;
    }
    if (!locked2d) {
        if (b2) { IMF2DBuffer_Release(b2); b2 = NULL; }
        if (FAILED(IMFMediaBuffer_Lock(buf, &data, &max, &cur)) || !data) { IMFMediaBuffer_Release(buf); return; }
        pitch = stride_attr;
    }
    if (!pitch) pitch = (LONG)(IsEqualGUID(sub, &MFVideoFormat_YUY2) ? 2 * w : (IsEqualGUID(sub, &MFVideoFormat_RGB32) || IsEqualGUID(sub, &MFVideoFormat_ARGB32)) ? 4 * w : w);
    if (!locked2d) {
        DWORD need = IsEqualGUID(sub, &MFVideoFormat_YUY2) ? 2 * w * h : (IsEqualGUID(sub, &MFVideoFormat_RGB32) || IsEqualGUID(sub, &MFVideoFormat_ARGB32)) ? 4 * w * h : w * h * 3 / 2;
        if (cur < need) { vs->short_buffers++; goto done; }
    }
    if (IsEqualGUID(sub, &MFVideoFormat_NV12)) {
        bt_nv12_to_bgra(data, pitch, data + (size_t)pitch * h, pitch, (int)w, (int)h, scratch);
        ok = 1;
    } else if (IsEqualGUID(sub, &MFVideoFormat_YUY2)) {
        bt_yuy2_to_bgra(data, pitch, (int)w, (int)h, scratch);
        ok = 1;
    } else if (IsEqualGUID(sub, &MFVideoFormat_I420) || IsEqualGUID(sub, &MFVideoFormat_IYUV)) {
        const uint8_t *u = data + (size_t)pitch * h, *v = u + (size_t)(pitch / 2) * (h / 2);
        bt_planar_to_bgra(data, pitch, u, v, pitch / 2, (int)w, (int)h, scratch);
        ok = 1;
    } else if (IsEqualGUID(sub, &MFVideoFormat_YV12)) {
        const uint8_t *v = data + (size_t)pitch * h, *u = v + (size_t)(pitch / 2) * (h / 2);
        bt_planar_to_bgra(data, pitch, u, v, pitch / 2, (int)w, (int)h, scratch);
        ok = 1;
    } else if (IsEqualGUID(sub, &MFVideoFormat_RGB32) || IsEqualGUID(sub, &MFVideoFormat_ARGB32)) {
        /* the address of the top row and the signed step to the next: a 2D buffer hands the top row first whatever the pitch's
         * sign; a plain buffer with a negative default stride holds the bottom row first */
        const BYTE *row0 = data;
        LONG step = pitch;
        UINT32 r;
        if (!locked2d && stride_attr < 0) { row0 = data + (size_t)(-stride_attr) * (h - 1); step = stride_attr; }
        for (r = 0; r < h; r++) bt_rgb32_to_bgra(row0 + (ptrdiff_t)r * step, 4 * (int)w, (int)w, 1, scratch + (size_t)r * w * 4);
        ok = 1;
    }
    if (ok) {
        int bar = bt_bgra_bar_length(scratch, (int)w, (int)h - 4), top = bt_bgra_bar_length(scratch, (int)w, 3);
        if (bar < 3 && top > bar + 10) {   /* the bar is along the top: upside down; turn it over for the window */
            int y;
            vs->flipped++;
            for (y = 0; y < (int)h; y++) memcpy(pic + (size_t)y * w * 4, scratch + (size_t)(h - 1 - y) * w * 4, (size_t)w * 4);
            bar = top;
        } else {
            memcpy(pic, scratch, sizeof scratch);
        }
        if (vs->frames < 64) vs->bars[vs->frames] = bar;
        if (vs->frames == 0) vs->bar_first = bar;
        vs->bar_last = bar;
        if (vs->frames == BT_CLIP_N / 2) {
            vs->hue_left = bt_bgra_hue(pic, (int)w, 4, 4);
            vs->hue_right = bt_bgra_hue(pic, (int)w, (int)w - 5, 4);
        }
        vs->frames++;
        g_pic_valid = shown;
    }
done:
    if (locked2d) IMF2DBuffer_Unlock2D(b2);
    else IMFMediaBuffer_Unlock(buf);
    if (b2) IMF2DBuffer_Release(b2);
    IMFMediaBuffer_Release(buf);
}

static int write_clip(const clip_t *c, WCHAR *wpath, size_t wcap)
{
    WCHAR dir[MAX_PATH];
    HANDLE f;
    DWORD n = GetTempPathW(MAX_PATH, dir), done = 0;
    WCHAR name[40];
    int i;

    if (n == 0 || n >= MAX_PATH) return 0;
    for (i = 0; c->ext[i] && i < 8; i++) name[i] = (WCHAR)c->ext[i];
    name[i] = 0;
    if (wcap < (size_t)n + 24) return 0;
    memcpy(wpath, dir, (n + 1) * sizeof(WCHAR));
    {
        static const WCHAR base[] = L"bcd-video-test";
        size_t at = n;
        for (i = 0; base[i]; i++) wpath[at++] = base[i];
        for (i = 0; name[i]; i++) wpath[at++] = name[i];
        wpath[at] = 0;
    }
    f = CreateFileW(wpath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    if (!WriteFile(f, c->data, (DWORD)c->size, &done, NULL) || done != c->size) { CloseHandle(f); return 0; }
    CloseHandle(f);
    return 1;
}

/* One clip, start to end. Returns the number of failed checks. */
static int play_clip(bt_panel *pn, const clip_t *c, int index)
{
    static const GUID *const vfmts[] = { &MFVideoFormat_NV12, &MFVideoFormat_YUY2, &MFVideoFormat_RGB32, &MFVideoFormat_I420, &MFVideoFormat_YV12 };
    static const GUID *const afmts[] = { &MFAudioFormat_Float, &MFAudioFormat_PCM };
    const int before = bt_g.fails;
    WCHAR wpath[MAX_PATH + 32];
    IMFSourceReader *rd = NULL;
    IMFMediaType *t = NULL;
    HRESULT hr;
    video_stats vs;
    GUID vsub = GUID_NULL, asub = GUID_NULL, nat = GUID_NULL;
    UINT32 w = 0, h = 0, num = 0, den = 0, ach = 0, arate = 0, abits = 0;
    LONG stride_attr = 0;
    char nb[32];
    int vi, ai, i, have_video = 0, have_audio = 0;
    double start, lastlog;
    long long afr = 0;
    double asq = 0;

    memset(&vs, 0, sizeof vs);
    g_pic_valid = 0;
    snprintf(g_caption, sizeof g_caption, "%s", c->name);
    bt_note(pn, BT_HEAD, "== %s, %lu bytes ==", c->name, (unsigned long)c->size);
    if (!write_clip(c, wpath, sizeof wpath / sizeof wpath[0])) {
        bt_report(pn, 0, c->name, "the clip could not be written to the temp folder (error %lu)", GetLastError());
        return bt_g.fails - before;
    }
    hr = p_create_reader(wpath, NULL, &rd);
    if (!bt_report(pn, SUCCEEDED(hr) && rd, "source reader opens the clip", "MFCreateSourceReaderFromURL %s", bt_hr(hr))) {
        bt_note(pn, BT_WARN, "  hint: %s", c->hint);
        DeleteFileW(wpath);
        return bt_g.fails - before;
    }
    IMFSourceReader_SetStreamSelection(rd, MF_SOURCE_READER_ALL_STREAMS, FALSE);
    have_video = SUCCEEDED(IMFSourceReader_SetStreamSelection(rd, MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE));
    have_audio = SUCCEEDED(IMFSourceReader_SetStreamSelection(rd, MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE));

    /* the native types */
    if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(rd, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &t)) && t) {
        IMFAttributes_GetGUID((IMFAttributes *)t, &MF_MT_SUBTYPE, &nat);
        type_size_rate(t, &w, &h, &num, &den);
        bt_note(pn, BT_INFO, "  video stream: %s %ux%u at %.2f fps", subtype_name(&nat, nb, sizeof nb), w, h, den ? (double)num / den : 0.0);
        IMFMediaType_Release(t);
        t = NULL;
    }
    if (SUCCEEDED(IMFSourceReader_GetNativeMediaType(rd, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &t)) && t) {
        IMFAttributes_GetGUID((IMFAttributes *)t, &MF_MT_SUBTYPE, &asub);
        IMFAttributes_GetUINT32((IMFAttributes *)t, &MF_MT_AUDIO_NUM_CHANNELS, &ach);
        IMFAttributes_GetUINT32((IMFAttributes *)t, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &arate);
        bt_note(pn, BT_INFO, "  audio stream: %s, %u channel(s), %u Hz", subtype_name(&asub, nb, sizeof nb), ach, arate);
        IMFMediaType_Release(t);
        t = NULL;
    }
    bt_report(pn, have_video && w == BT_CLIP_W && h == BT_CLIP_H, "video stream found", "%s %ux%u (expected %dx%d)", have_video ? "yes" : "no", w, h, BT_CLIP_W, BT_CLIP_H);
    if (!have_video || w != BT_CLIP_W || h != BT_CLIP_H) {
        bt_note(pn, BT_WARN, "  hint: %s", c->hint);
        IMFSourceReader_Release(rd);
        DeleteFileW(wpath);
        return bt_g.fails - before;
    }

    vi = choose_output(rd, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &MFMediaType_Video, vfmts, 5, pn, c->name);
    bt_report(pn, vi >= 0, "raw video output accepted", "%s", vi >= 0 ? subtype_name(vfmts[vi], nb, sizeof nb) : "none of NV12, YUY2, RGB32, I420, YV12");
    if (vi < 0) {
        bt_note(pn, BT_WARN, "  hint: %s", c->hint);
        IMFSourceReader_Release(rd);
        DeleteFileW(wpath);
        return bt_g.fails - before;
    }
    vsub = *vfmts[vi];
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(rd, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &t)) && t) {
        UINT32 sw = 0, sh = 0, sn = 0, sd = 0, stride = 0;
        type_size_rate(t, &sw, &sh, &sn, &sd);
        if (sw && sh) { w = sw; h = sh; }
        if (SUCCEEDED(IMFAttributes_GetUINT32((IMFAttributes *)t, &MF_MT_DEFAULT_STRIDE, &stride))) stride_attr = (LONG)stride;
        bt_note(pn, BT_INFO, "  current type: %s %ux%u, default stride %ld", subtype_name(&vsub, nb, sizeof nb), w, h, (long)stride_attr);
        IMFMediaType_Release(t);
        t = NULL;
    }
    ai = have_audio ? choose_output(rd, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &MFMediaType_Audio, afmts, 2, pn, c->name) : -1;
    if (have_audio) {
        if (ai >= 0 && SUCCEEDED(IMFSourceReader_GetCurrentMediaType(rd, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &t)) && t) {
            IMFAttributes_GetUINT32((IMFAttributes *)t, &MF_MT_AUDIO_NUM_CHANNELS, &ach);
            IMFAttributes_GetUINT32((IMFAttributes *)t, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &arate);
            IMFAttributes_GetUINT32((IMFAttributes *)t, &MF_MT_AUDIO_BITS_PER_SAMPLE, &abits);
            IMFMediaType_Release(t);
            t = NULL;
        }
        bt_report(pn, ai >= 0, "PCM audio output accepted", "%s, %u channel(s), %u Hz, %u bit", ai >= 0 ? subtype_name(afmts[ai], nb, sizeof nb) : "neither float nor 16-bit PCM", ach, arate, abits);
    }

    /* the pictures, at their own pace */
    start = bt_now();
    lastlog = start;
    for (;;) {
        DWORD actual = 0, flags = 0;
        LONGLONG ts = 0;
        IMFSample *sample = NULL;

        if (!bt_pump(pn)) { IMFSourceReader_Release(rd); DeleteFileW(wpath); return bt_g.fails - before; }
        hr = IMFSourceReader_ReadSample(rd, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &actual, &flags, &ts, &sample);
        if (FAILED(hr)) {
            bt_report(pn, 0, "reading the pictures", "ReadSample %s after %d pictures", bt_hr(hr), vs.frames);
            break;
        }
        if (flags & (MF_SOURCE_READERF_ERROR)) { bt_report(pn, 0, "reading the pictures", "the reader reports an error after %d pictures", vs.frames); break; }
        if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
            if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(rd, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &t)) && t) {
                IMFAttributes_GetGUID((IMFAttributes *)t, &MF_MT_SUBTYPE, &vsub);
                IMFMediaType_Release(t);
                t = NULL;
            }
            bt_note(pn, BT_INFO, "  the output type changed to %s", subtype_name(&vsub, nb, sizeof nb));
        }
        if (sample) {
            double due = start + ts / 1e7;
            if (vs.frames == 0) vs.ts_first = ts;
            vs.ts_last = ts;
            take_frame(sample, &vsub, w, h, stride_attr, &vs, 1);
            snprintf(g_caption, sizeof g_caption, "%s\nframe %d, %.2f s, bar %d px", c->name, vs.frames, ts / 1e7, vs.bar_last);
            InvalidateRect(pn->hwnd, NULL, FALSE);
            IMFSample_Release(sample);
            while (bt_now() < due && bt_pump(pn)) Sleep(2);   /* real time */
        }
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (bt_now() - start > 20.0) { bt_report(pn, 0, "reading the pictures", "no end of stream after 20 s (%d pictures)", vs.frames); break; }
        if (bt_now() - lastlog > 5.0) { lastlog = bt_now(); bt_log("still reading: %d pictures", vs.frames); }
        if (!sample && !(flags & (MF_SOURCE_READERF_ENDOFSTREAM | MF_SOURCE_READERF_STREAMTICK | MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED))) Sleep(1);
    }

    /* the verdicts on the pictures */
    for (i = 0; i < vs.frames && i < 64; i++) {
        int ex = bt_clip_expected_bar(i), ex1 = i > 0 ? bt_clip_expected_bar(i - 1) : ex;
        if (abs(vs.bars[i] - ex) <= 8 || abs(vs.bars[i] - ex1) <= 8) vs.bars_ok++;
        if (i > 0 && vs.bars[i] + 3 < vs.bars[i - 1]) vs.order_breaks++;
    }
    snprintf(g_clip_line[index], sizeof g_clip_line[index], "%d pictures, bar %d to %d px, %d of %d in order and within 8 px", vs.frames, vs.bar_first, vs.bar_last, vs.bars_ok, vs.frames);
    bt_report(pn, vs.frames >= 28 && vs.frames <= 33, "pictures decoded", "%d of %d (28 to 33 is right)%s", vs.frames, BT_CLIP_N, vs.short_buffers ? ", some buffers too short" : "");
    bt_report(pn, vs.frames > 0 && vs.bars_ok * 10 >= vs.frames * 9 && vs.order_breaks == 0, "pictures are the right ones in the right order",
              "progress bar %d px first, %d px last (expected %d to %d); %d of %d within 8 px; %d out of order", vs.bar_first, vs.bar_last, bt_clip_expected_bar(0),
              bt_clip_expected_bar(BT_CLIP_N - 1), vs.bars_ok, vs.frames, vs.order_breaks);
    bt_report(pn, vs.flipped == 0, "picture is the right way up", "%d of %d pictures were upside down", vs.flipped, vs.frames);
    bt_report(pn, vs.hue_left == 1 && vs.hue_right == 2, "colours: red left half, blue right half", "left %s, right %s", vs.hue_left == 1 ? "red" : vs.hue_left == 2 ? "blue" : "neither",
              vs.hue_right == 2 ? "blue" : vs.hue_right == 1 ? "red" : "neither");
    {
        double first = vs.ts_first / 1e7, last = vs.ts_last / 1e7, step = vs.frames > 1 ? (last - first) / (vs.frames - 1) : 0;
        bt_report(pn, last >= 1.75 && last <= 2.2 && step > 0.05 && step < 0.09, "timestamps", "first %.3f s, last %.3f s, %.1f ms a picture (expected 66.7)", first, last, step * 1000);
    }

    /* the audio */
    if (have_audio && ai >= 0) {
        long long samples = 0;
        double elapsed;
        for (;;) {
            DWORD actual = 0, flags = 0;
            LONGLONG ts = 0;
            IMFSample *sample = NULL;

            if (!bt_pump(pn)) break;
            hr = IMFSourceReader_ReadSample(rd, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &actual, &flags, &ts, &sample);
            if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR)) { bt_report(pn, 0, "reading the audio", "ReadSample %s after %lld samples", bt_hr(hr), samples); break; }
            if (sample) {
                IMFMediaBuffer *buf = NULL;
                BYTE *d = NULL;
                DWORD cur = 0, max = 0;
                if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buf)) && buf && SUCCEEDED(IMFMediaBuffer_Lock(buf, &d, &max, &cur)) && d) {
                    int isfloat = IsEqualGUID(afmts[ai], &MFAudioFormat_Float);
                    DWORD step = (isfloat ? 4 : 2) * (ach ? ach : 1), k;
                    for (k = 0; k + step <= cur; k += step) {
                        double v = isfloat ? *(const float *)(d + k) : *(const short *)(d + k) / 32768.0;
                        asq += v * v;
                        samples++;
                    }
                    IMFMediaBuffer_Unlock(buf);
                }
                if (buf) IMFMediaBuffer_Release(buf);
                IMFSample_Release(sample);
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
            elapsed = bt_now() - start;
            if (elapsed > 40.0) { bt_report(pn, 0, "reading the audio", "no end of stream after 40 s"); break; }
        }
        afr = samples;
        {
            double rms = afr > 0 ? sqrt(asq / (double)afr) : 0.0, secs = arate ? (double)afr / arate : 0.0;
            bt_report(pn, secs >= 1.8 && secs <= 2.3 && rms >= 0.05, "audio decoded", "%lld sample frames = %.2f s (expected 2.00), level (RMS) %.3f (the tone is 0.35)", afr, secs, rms);
        }
    } else if (have_audio) {
        bt_report(pn, 0, "audio decoded", "no PCM output could be set");
    } else {
        bt_report(pn, 0, "audio stream found", "none");
    }
    if (bt_g.fails > before) bt_note(pn, BT_WARN, "  hint: %s", c->hint);
    IMFSourceReader_Release(rd);
    DeleteFileW(wpath);
    return bt_g.fails - before;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    bt_panel *pn;
    HMODULE mfplat, mfrw;
    startup_fn startup;
    shutdown_fn shutdown;
    HRESULT hr;
    int again;
    size_t i;

    (void)inst; (void)prev; (void)cmd; (void)show;
    bt_init("video");
    pn = bt_panel_new("video test", 720, 600);
    if (!pn) { bt_check(0, "window", "could not be created"); bt_result(); return 1; }
    pn->hook_h = 2 * BT_CLIP_H + 16;
    pn->paint_hook = paint_hook;
    bt_panel_button(pn, 'R', "Run again");
    bt_panel_button(pn, 'Q', "Close");
    snprintf(g_caption, sizeof g_caption, "starting");

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    mfplat = LoadLibraryA("mfplat.dll");
    mfrw = LoadLibraryA("mfreadwrite.dll");
    startup = mfplat ? (startup_fn)GetProcAddress(mfplat, "MFStartup") : NULL;
    shutdown = mfplat ? (shutdown_fn)GetProcAddress(mfplat, "MFShutdown") : NULL;
    p_create_type = mfplat ? (createtype_fn)GetProcAddress(mfplat, "MFCreateMediaType") : NULL;
    p_create_reader = mfrw ? (createreader_fn)GetProcAddress(mfrw, "MFCreateSourceReaderFromURL") : NULL;
    if (!startup || !shutdown || !p_create_type || !p_create_reader) {
        bt_report(pn, 0, "Media Foundation", "mfplat.dll / mfreadwrite.dll not complete: MFStartup %p, MFCreateMediaType %p, MFCreateSourceReaderFromURL %p",
                  (void *)startup, (void *)p_create_type, (void *)p_create_reader);
        bt_result();
        bt_panel_title(pn, "video test", bt_g.head);
        while (bt_wait_click(pn)) {}
        return 1;
    }
    hr = startup(MF_VERSION, MFSTARTUP_FULL);
    if (!bt_report(pn, SUCCEEDED(hr), "MFStartup", "%s", bt_hr(hr))) {
        bt_result();
        bt_panel_title(pn, "video test", bt_g.head);
        while (bt_wait_click(pn)) {}
        return 1;
    }
    bt_note(pn, BT_INFO, "this is a %d-bit process; BCD's Media Foundation video is a 32-bit feature by default (docs/MEDIA.md)", BT_BITS);

    do {
        again = 0;
        for (i = 0; i < sizeof clips / sizeof clips[0]; i++) {
            g_clip_line[i][0] = 0;
            play_clip(pn, &clips[i], (int)i);
            if (!g_clip_line[i][0]) snprintf(g_clip_line[i], sizeof g_clip_line[i], "no pictures (see the FAIL lines)");
            if (pn->closed) break;
        }
        bt_headline("%d-bit process; MP4: %s; WMV: %s", BT_BITS, g_clip_line[0], g_clip_line[1]);
        bt_result();
        bt_panel_title(pn, "video test", bt_g.head);
        bt_panel_line(pn, bt_g.fails ? BT_FAIL : BT_PASS, "RESULT %s: %d of %d checks passed. Send Log to keep this.", bt_g.fails ? "FAIL" : "PASS", bt_g.checks - bt_g.fails, bt_g.checks);
        {
            int id = bt_wait_click(pn);
            if (id == 'Q') PostMessageA(pn->hwnd, WM_CLOSE, 0, 0);
            if (id == 'R') {
                again = 1;
                bt_g.checks = bt_g.fails = 0;
                bt_panel_clear(pn);
                bt_panel_title(pn, "video test", "");
            }
        }
    } while (again && !pn->closed);
    shutdown();
    return 0;
}
