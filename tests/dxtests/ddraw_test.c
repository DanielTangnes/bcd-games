// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's DirectDraw test (round 602): the 2D API of the games before Direct3D, 32-bit like they are. BCD has no OpenGL, which
// Wine's ddraw draws with (through wined3d), so this shows whether DirectDraw works in the session at all, with whichever
// ddraw.dll it was given.
//
// Windowed part (starts by itself): the legacy entry points (DirectDrawEnumerate, DirectDrawCreate, QueryInterface to
// IDirectDraw7, DirectDrawCreateEx), the caps and display modes, a primary surface with a clipper, off-screen surfaces, a
// colour fill, a locked-surface write read back through the pixel format's masks, a stretch blit, a source colour key blit and
// an 8-bit palettised surface with a palette, all PASS or FAIL with the numbers read back. Then a window of animation: a
// gradient, a sprite that moves under a colour key, and the check results as text drawn with GetDC, blitted to the primary
// surface 60 times a second; two seconds of it give the verdict (frames and rate).
//
// Full-screen part (only when asked, because it changes the display mode: press F or tap the window): exclusive mode,
// SetDisplayMode 640x480x8, a flipping primary surface with a back buffer, a palette on the primary, an index ramp drawn into
// the back buffer and flipped for about 3 seconds, the display mode read back, RestoreDisplayMode.
//
// Every line goes to the session log like the other tests' ("[bcd-test] ddraw (32-bit): PASS|FAIL ..."), ends with one
// "RESULT" line, and the window title carries the verdict.

#define COBJMACROS
#include "bcdtest.h"
#include "bcdstats.h"
#include <ddraw.h>

#define W 640
#define H 480

typedef HRESULT (WINAPI *create_fn)(GUID *, LPDIRECTDRAW *, IUnknown *);
typedef HRESULT (WINAPI *createex_fn)(GUID *, void **, REFIID, IUnknown *);
typedef HRESULT (WINAPI *enumerate_fn)(LPDDENUMCALLBACKA, void *);

static HWND g_hwnd;
static volatile int g_key, g_tap, g_closed, g_repaint;

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) PostMessageA(h, WM_CLOSE, 0, 0);
        else g_key = (int)w;
        return 0;
    case WM_LBUTTONUP:
        g_tap = 1;
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(h, &ps);   /* DirectDraw draws the window; there is nothing for GDI to paint */
        EndPaint(h, &ps);
        g_repaint = 1;
        return 0;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_CLOSE:
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        g_closed = 1;
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(h, m, w, l);
}

static HWND make_window(const char *title)
{
    WNDCLASSA wc;
    RECT r = { 0, 0, W, H };
    const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    HWND hwnd;

    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "BCDDirectDrawTest";
    if (!RegisterClassA(&wc)) return NULL;
    AdjustWindowRect(&r, style, FALSE);
    hwnd = CreateWindowExA(0, wc.lpszClassName, title, style, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
    if (hwnd) { ShowWindow(hwnd, SW_SHOW); UpdateWindow(hwnd); }
    return hwnd;
}

static int pump(void)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return !g_closed;
}

/* ------------------------------------------------------------------ surfaces and pixels */

static IDirectDrawSurface7 *make_surface(IDirectDraw7 *dd, int w, int h, DWORD caps, const DDPIXELFORMAT *pf, HRESULT *hr)
{
    DDSURFACEDESC2 sd;
    IDirectDrawSurface7 *s = NULL;

    memset(&sd, 0, sizeof sd);
    sd.dwSize = sizeof sd;
    sd.dwFlags = DDSD_CAPS | DDSD_WIDTH | DDSD_HEIGHT;
    sd.dwWidth = (DWORD)w;
    sd.dwHeight = (DWORD)h;
    sd.ddsCaps.dwCaps = DDSCAPS_OFFSCREENPLAIN | caps;
    if (pf) { sd.dwFlags |= DDSD_PIXELFORMAT; sd.ddpfPixelFormat = *pf; }
    *hr = IDirectDraw7_CreateSurface(dd, &sd, &s, NULL);
    return SUCCEEDED(*hr) ? s : NULL;
}

static HRESULT fill(IDirectDrawSurface7 *s, const RECT *r, DWORD color)
{
    DDBLTFX fx;
    memset(&fx, 0, sizeof fx);
    fx.dwSize = sizeof fx;
    fx.dwFillColor = color;
    return IDirectDrawSurface7_Blt(s, (RECT *)r, NULL, NULL, DDBLT_COLORFILL | DDBLT_WAIT, &fx);
}

static DWORD px_get(const DDSURFACEDESC2 *sd, int x, int y)
{
    const BYTE *p = (const BYTE *)sd->lpSurface + (size_t)y * (size_t)sd->lPitch;
    switch (sd->ddpfPixelFormat.dwRGBBitCount) {
    case 8: return p[x];
    case 16: return *(const WORD *)(p + 2 * x);
    case 24: return p[3 * x] | (p[3 * x + 1] << 8) | ((DWORD)p[3 * x + 2] << 16);
    default: return *(const DWORD *)(p + 4 * x);
    }
}

static void px_put(const DDSURFACEDESC2 *sd, int x, int y, DWORD v)
{
    BYTE *p = (BYTE *)sd->lpSurface + (size_t)y * (size_t)sd->lPitch;
    switch (sd->ddpfPixelFormat.dwRGBBitCount) {
    case 8: p[x] = (BYTE)v; break;
    case 16: *(WORD *)(p + 2 * x) = (WORD)v; break;
    case 24: p[3 * x] = (BYTE)v; p[3 * x + 1] = (BYTE)(v >> 8); p[3 * x + 2] = (BYTE)(v >> 16); break;
    default: *(DWORD *)(p + 4 * x) = v; break;
    }
}

typedef struct { DWORD r, g, b; int bits; } fmt_t;

static DWORD pack(const fmt_t *f, int r, int g, int b) { return bt_pack_rgb(f->r, f->g, f->b, r, g, b); }

static int near_rgb(const fmt_t *f, DWORD px, int r, int g, int b)
{
    int rr, gg, bb;
    bt_unpack_rgb(f->r, f->g, f->b, px, &rr, &gg, &bb);
    return abs(rr - r) <= 9 && abs(gg - g) <= 9 && abs(bb - b) <= 9;   /* 5-6-5 loses up to 7 */
}

/* ------------------------------------------------------------------ the state of the windowed part */

typedef struct {
    IDirectDraw7 *dd;
    IDirectDrawSurface7 *primary, *work, *sprite;
    IDirectDrawClipper *clip;
    fmt_t fmt;
} dd_state;

static char g_disp[64] = "?";   /* the display mode, for the RESULT line */
static char g_lines[8][96];   /* the check results shown in the window */
static int g_nlines;

static BOOL WINAPI enum_cb(GUID *guid, LPSTR desc, LPSTR name, void *ctx)
{
    (void)guid;
    if (*(int *)ctx < 3) bt_log("DirectDrawEnumerate: \"%s\" (%s)", desc ? desc : "", name ? name : "");
    (*(int *)ctx)++;
    return TRUE;
}

typedef struct { int count, has640x480x8, has640x480x16, has640x480x32, w, h; } modes_t;

static HRESULT WINAPI mode_cb(DDSURFACEDESC2 *sd, void *ctx)
{
    modes_t *m = (modes_t *)ctx;
    m->count++;
    if (sd->dwWidth == 640 && sd->dwHeight == 480) {
        if (sd->ddpfPixelFormat.dwRGBBitCount == 8) m->has640x480x8 = 1;
        if (sd->ddpfPixelFormat.dwRGBBitCount == 16) m->has640x480x16 = 1;
        if (sd->ddpfPixelFormat.dwRGBBitCount == 32) m->has640x480x32 = 1;
    }
    return DDENUMRET_OK;
}

/* A result both for the log and for the window's text. */
static int res(dd_state *st, int ok, const char *what, const char *fmt, ...)
{
    char details[260];
    va_list ap;

    details[0] = 0;
    if (fmt) {
        va_start(ap, fmt);
        vsnprintf(details, sizeof details, fmt, ap);
        va_end(ap);
    }
    bt_check(ok, what, "%s", details);
    (void)st;
    if (g_nlines < 8) {
        snprintf(g_lines[g_nlines], sizeof g_lines[0], "%s %s %s", ok ? "PASS" : "FAIL", what, details);
        g_nlines++;
    }
    return ok;
}

static void release_all(dd_state *st)
{
    if (st->sprite) IDirectDrawSurface7_Release(st->sprite);
    if (st->work) IDirectDrawSurface7_Release(st->work);
    if (st->primary) IDirectDrawSurface7_Release(st->primary);
    if (st->clip) IDirectDrawClipper_Release(st->clip);
    if (st->dd) IDirectDraw7_Release(st->dd);
    memset(st, 0, sizeof *st);
}

/* The checks. Returns 0 when nothing can be drawn at all (no DirectDraw object, no primary surface, no work surface). */
static int open_windowed(dd_state *st, HMODULE dll, int first)
{
    createex_fn createex = (createex_fn)GetProcAddress(dll, "DirectDrawCreateEx");
    create_fn create = (create_fn)GetProcAddress(dll, "DirectDrawCreate");
    enumerate_fn enumerate = (enumerate_fn)GetProcAddress(dll, "DirectDrawEnumerateA");
    DDSURFACEDESC2 sd;
    DDPIXELFORMAT pf;
    HRESULT hr;
    modes_t modes;
    int n = 0;
    DDCAPS caps7;

    memset(st, 0, sizeof *st);
    if (first && enumerate) {
        hr = enumerate(enum_cb, &n);
        res(st, SUCCEEDED(hr) && n > 0, "DirectDrawEnumerateA", "%d driver(s), %s", n, bt_hr(hr));
    }
    if (first && create) {   /* the oldest entry point: an IDirectDraw, then the newer interface from it */
        LPDIRECTDRAW dd1 = NULL;
        hr = create(NULL, &dd1, NULL);
        if (SUCCEEDED(hr) && dd1) {
            IDirectDraw7 *via = NULL;
            HRESULT qh = IDirectDraw_QueryInterface(dd1, &IID_IDirectDraw7, (void **)&via);
            res(st, SUCCEEDED(qh), "DirectDrawCreate + QueryInterface(IDirectDraw7)", "create %s, query %s", bt_hr(hr), bt_hr(qh));
            if (via) IDirectDraw7_Release(via);
            IDirectDraw_Release(dd1);
        } else {
            res(st, 0, "DirectDrawCreate", "%s", bt_hr(hr));
        }
    }
    if (!createex) { res(st, 0, "DirectDrawCreateEx", "ddraw.dll has no such export"); return 0; }
    hr = createex(NULL, (void **)&st->dd, &IID_IDirectDraw7, NULL);
    if (!res(st, SUCCEEDED(hr) && st->dd, "DirectDrawCreateEx(IDirectDraw7)", "%s", bt_hr(hr))) return 0;

    memset(&caps7, 0, sizeof caps7);
    caps7.dwSize = sizeof caps7;
    hr = IDirectDraw7_GetCaps(st->dd, &caps7, NULL);
    if (first)
        res(st, SUCCEEDED(hr), "GetCaps", "video memory %lu of %lu KB free, caps %08lx, colour key caps %08lx", (unsigned long)caps7.dwVidMemFree / 1024,
            (unsigned long)caps7.dwVidMemTotal / 1024, (unsigned long)caps7.dwCaps, (unsigned long)caps7.dwCKeyCaps);

    memset(&sd, 0, sizeof sd);
    sd.dwSize = sizeof sd;
    hr = IDirectDraw7_GetDisplayMode(st->dd, &sd);
    if (SUCCEEDED(hr)) snprintf(g_disp, sizeof g_disp, "%lux%lu %lu-bit", (unsigned long)sd.dwWidth, (unsigned long)sd.dwHeight, (unsigned long)sd.ddpfPixelFormat.dwRGBBitCount);
    if (first)
        res(st, SUCCEEDED(hr) && sd.dwWidth > 0, "GetDisplayMode", "%lux%lu, %lu bit, %lu Hz", (unsigned long)sd.dwWidth, (unsigned long)sd.dwHeight,
            (unsigned long)sd.ddpfPixelFormat.dwRGBBitCount, (unsigned long)sd.dwRefreshRate);
    memset(&modes, 0, sizeof modes);
    hr = IDirectDraw7_EnumDisplayModes(st->dd, 0, NULL, &modes, mode_cb);
    if (first)
        res(st, SUCCEEDED(hr) && modes.count > 0, "EnumDisplayModes", "%d modes; 640x480 in 8 bit: %s, 16 bit: %s, 32 bit: %s", modes.count,
            modes.has640x480x8 ? "yes" : "no", modes.has640x480x16 ? "yes" : "no", modes.has640x480x32 ? "yes" : "no");

    hr = IDirectDraw7_SetCooperativeLevel(st->dd, g_hwnd, DDSCL_NORMAL);
    if (!res(st, SUCCEEDED(hr), "SetCooperativeLevel(NORMAL)", "%s", bt_hr(hr))) return 0;

    memset(&sd, 0, sizeof sd);
    sd.dwSize = sizeof sd;
    sd.dwFlags = DDSD_CAPS;
    sd.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE;
    hr = IDirectDraw7_CreateSurface(st->dd, &sd, &st->primary, NULL);
    if (!res(st, SUCCEEDED(hr) && st->primary, "primary surface", "%s", bt_hr(hr))) return 0;
    hr = IDirectDraw7_CreateClipper(st->dd, 0, &st->clip, NULL);
    if (SUCCEEDED(hr)) hr = IDirectDrawClipper_SetHWnd(st->clip, 0, g_hwnd);
    if (SUCCEEDED(hr)) hr = IDirectDrawSurface7_SetClipper(st->primary, st->clip);
    res(st, SUCCEEDED(hr), "clipper on the primary surface", "%s", bt_hr(hr));

    memset(&pf, 0, sizeof pf);
    pf.dwSize = sizeof pf;
    hr = IDirectDrawSurface7_GetPixelFormat(st->primary, &pf);
    if (SUCCEEDED(hr) && (pf.dwFlags & DDPF_RGB) && pf.dwRGBBitCount >= 15) {
        st->fmt.r = pf.dwRBitMask; st->fmt.g = pf.dwGBitMask; st->fmt.b = pf.dwBBitMask; st->fmt.bits = (int)pf.dwRGBBitCount;
    } else {   /* a palettised or unknown desktop: take 32-bit XRGB for the surfaces made here */
        st->fmt.r = 0xFF0000; st->fmt.g = 0xFF00; st->fmt.b = 0xFF; st->fmt.bits = 32;
    }
    if (first)
        res(st, SUCCEEDED(hr), "primary pixel format", "%d bit, masks r %06lx g %06lx b %06lx", st->fmt.bits, (unsigned long)st->fmt.r, (unsigned long)st->fmt.g,
            (unsigned long)st->fmt.b);

    /* the work surface: the animation is drawn here and blitted to the window; the display's format, video memory first */
    st->work = make_surface(st->dd, W, H, DDSCAPS_VIDEOMEMORY, NULL, &hr);
    if (!st->work) {
        HRESULT vh = hr;
        st->work = make_surface(st->dd, W, H, DDSCAPS_SYSTEMMEMORY, NULL, &hr);
        if (first) res(st, st->work != NULL, "off-screen surface 640x480", "video memory %s, system memory %s", bt_hr(vh), bt_hr(hr));
    } else if (first) {
        res(st, 1, "off-screen surface 640x480", "in video memory");
    }
    if (!st->work) return 0;

    if (first) {
        DDSURFACEDESC2 lk;
        RECT quarter = { 0, 0, 64, 64 };
        DWORD want, got;
        int ok, x, y;

        /* a colour fill, read back through the pixel format */
        want = pack(&st->fmt, 200, 60, 20);
        hr = fill(st->work, &quarter, want);
        memset(&lk, 0, sizeof lk);
        lk.dwSize = sizeof lk;
        if (SUCCEEDED(hr) && SUCCEEDED(hr = IDirectDrawSurface7_Lock(st->work, NULL, &lk, DDLOCK_WAIT | DDLOCK_READONLY, NULL))) {
            got = px_get(&lk, 10, 10) & (st->fmt.bits >= 32 ? 0xFFFFFF : 0xFFFFFFFFu);
            IDirectDrawSurface7_Unlock(st->work, NULL);
            ok = near_rgb(&st->fmt, got, 200, 60, 20);
            res(st, ok, "colour fill (Blt, DDBLT_COLORFILL)", "wrote %06lx, read %06lx", (unsigned long)want, (unsigned long)got);
        } else {
            res(st, 0, "colour fill (Blt, DDBLT_COLORFILL)", "%s", bt_hr(hr));
        }

        /* a locked write, read back */
        memset(&lk, 0, sizeof lk);
        lk.dwSize = sizeof lk;
        hr = IDirectDrawSurface7_Lock(st->work, NULL, &lk, DDLOCK_WAIT | DDLOCK_WRITEONLY, NULL);
        if (SUCCEEDED(hr)) {
            for (y = 0; y < 64; y++)
                for (x = 0; x < 64; x++) px_put(&lk, 100 + x, y, pack(&st->fmt, x * 4, y * 4, (x ^ y) * 4));
            IDirectDrawSurface7_Unlock(st->work, NULL);
            memset(&lk, 0, sizeof lk);
            lk.dwSize = sizeof lk;
            hr = IDirectDrawSurface7_Lock(st->work, NULL, &lk, DDLOCK_WAIT | DDLOCK_READONLY, NULL);
            if (SUCCEEDED(hr)) {
                got = px_get(&lk, 100 + 40, 20);
                IDirectDrawSurface7_Unlock(st->work, NULL);
                ok = near_rgb(&st->fmt, got, 160, 80, ((40 ^ 20) * 4) & 0xFF);
                res(st, ok, "Lock, write, Unlock, Lock, read", "pixel (140,20) is %06lx, expected r 160 g 80 b %d", (unsigned long)got, ((40 ^ 20) * 4) & 0xFF);
            } else {
                res(st, 0, "Lock, write, Unlock, Lock, read", "second Lock %s", bt_hr(hr));
            }
        } else {
            res(st, 0, "Lock, write, Unlock, Lock, read", "first Lock %s", bt_hr(hr));
        }

        /* a stretch blit within the surface: the 64x64 patch at (100,0) becomes 128x128 at (300,0) */
        {
            RECT src = { 100, 0, 164, 64 }, dst = { 300, 0, 428, 128 };
            hr = IDirectDrawSurface7_Blt(st->work, &dst, st->work, &src, DDBLT_WAIT, NULL);
            memset(&lk, 0, sizeof lk);
            lk.dwSize = sizeof lk;
            if (SUCCEEDED(hr) && SUCCEEDED(hr = IDirectDrawSurface7_Lock(st->work, NULL, &lk, DDLOCK_WAIT | DDLOCK_READONLY, NULL))) {
                DWORD a = px_get(&lk, 300 + 80, 40), b = px_get(&lk, 100 + 40, 20);
                IDirectDrawSurface7_Unlock(st->work, NULL);
                res(st, near_rgb(&st->fmt, a, 160, 80, ((40 ^ 20) * 4) & 0xFF) || a == b, "stretch blit 64x64 to 128x128", "(380,40) is %06lx, source (140,20) %06lx", (unsigned long)a,
                    (unsigned long)b);
            } else {
                res(st, 0, "stretch blit 64x64 to 128x128", "%s", bt_hr(hr));
            }
        }

        /* a source colour key: magenta is transparent */
        {
            IDirectDrawSurface7 *key = make_surface(st->dd, 32, 32, DDSCAPS_SYSTEMMEMORY, NULL, &hr);
            if (key) {
                DDCOLORKEY ck;
                RECT all = { 0, 0, 32, 32 }, mid = { 8, 8, 24, 24 }, at = { 500, 0, 532, 32 }, back = { 500, 0, 532, 32 };
                DWORD magenta = pack(&st->fmt, 255, 0, 255);
                fill(key, &all, magenta);
                fill(key, &mid, pack(&st->fmt, 0, 220, 0));
                ck.dwColorSpaceLowValue = ck.dwColorSpaceHighValue = magenta;
                hr = IDirectDrawSurface7_SetColorKey(key, DDCKEY_SRCBLT, &ck);
                fill(st->work, &back, pack(&st->fmt, 0, 0, 220));
                if (SUCCEEDED(hr)) hr = IDirectDrawSurface7_Blt(st->work, &at, key, NULL, DDBLT_KEYSRC | DDBLT_WAIT, NULL);
                memset(&lk, 0, sizeof lk);
                lk.dwSize = sizeof lk;
                if (SUCCEEDED(hr) && SUCCEEDED(hr = IDirectDrawSurface7_Lock(st->work, NULL, &lk, DDLOCK_WAIT | DDLOCK_READONLY, NULL))) {
                    DWORD corner = px_get(&lk, 502, 2), centre = px_get(&lk, 516, 16);
                    IDirectDrawSurface7_Unlock(st->work, NULL);
                    res(st, near_rgb(&st->fmt, corner, 0, 0, 220) && near_rgb(&st->fmt, centre, 0, 220, 0), "source colour key blit (DDBLT_KEYSRC)",
                        "keyed corner %06lx (blue kept), centre %06lx (green drawn)", (unsigned long)corner, (unsigned long)centre);
                } else {
                    res(st, 0, "source colour key blit (DDBLT_KEYSRC)", "%s", bt_hr(hr));
                }
                IDirectDrawSurface7_Release(key);
            } else {
                res(st, 0, "source colour key blit (DDBLT_KEYSRC)", "key surface %s", bt_hr(hr));
            }
        }

        /* an 8-bit palettised surface with a palette, blitted to the display-format surface */
        {
            DDPIXELFORMAT p8;
            IDirectDrawSurface7 *pal8;
            PALETTEENTRY ent[256], back_ent[256];
            IDirectDrawPalette *pal = NULL;
            int i;

            memset(&p8, 0, sizeof p8);
            p8.dwSize = sizeof p8;
            p8.dwFlags = DDPF_RGB | DDPF_PALETTEINDEXED8;
            p8.dwRGBBitCount = 8;
            for (i = 0; i < 256; i++) {
                ent[i].peRed = (BYTE)i; ent[i].peGreen = (BYTE)(255 - i); ent[i].peBlue = (BYTE)((i * 3) & 255); ent[i].peFlags = 0;
            }
            hr = IDirectDraw7_CreatePalette(st->dd, DDPCAPS_8BIT | DDPCAPS_ALLOW256, ent, &pal, NULL);
            pal8 = SUCCEEDED(hr) ? make_surface(st->dd, 64, 64, DDSCAPS_SYSTEMMEMORY, &p8, &hr) : NULL;
            if (pal && pal8) {
                HRESULT sh = IDirectDrawSurface7_SetPalette(pal8, pal), gh;
                int ok_entries;
                DDSURFACEDESC2 lk;
                RECT dst = { 560, 0, 624, 64 };
                memset(back_ent, 0, sizeof back_ent);
                gh = IDirectDrawPalette_GetEntries(pal, 0, 0, 256, back_ent);
                ok_entries = SUCCEEDED(gh) && back_ent[0].peGreen == 255 && back_ent[1].peRed == 1 && back_ent[128].peRed == 128 && back_ent[255].peGreen == 0;
                res(st, SUCCEEDED(sh) && ok_entries, "palette: 256 entries on an 8-bit surface", "SetPalette %s, GetEntries %s, entry 128 = %d,%d,%d", bt_hr(sh), bt_hr(gh),
                    back_ent[128].peRed, back_ent[128].peGreen, back_ent[128].peBlue);
                memset(&lk, 0, sizeof lk);
                lk.dwSize = sizeof lk;
                if (SUCCEEDED(hr = IDirectDrawSurface7_Lock(pal8, NULL, &lk, DDLOCK_WAIT | DDLOCK_WRITEONLY, NULL))) {
                    int x, y;
                    for (y = 0; y < 64; y++)
                        for (x = 0; x < 64; x++) ((BYTE *)lk.lpSurface)[y * lk.lPitch + x] = (BYTE)(x * 4);
                    IDirectDrawSurface7_Unlock(pal8, NULL);
                    hr = IDirectDrawSurface7_Blt(st->work, &dst, pal8, NULL, DDBLT_WAIT, NULL);
                    memset(&lk, 0, sizeof lk);
                    lk.dwSize = sizeof lk;
                    if (SUCCEEDED(hr) && SUCCEEDED(hr = IDirectDrawSurface7_Lock(st->work, NULL, &lk, DDLOCK_WAIT | DDLOCK_READONLY, NULL))) {
                        DWORD got = px_get(&lk, 560 + 32, 10);   /* column 32 has index 128 */
                        IDirectDrawSurface7_Unlock(st->work, NULL);
                        res(st, near_rgb(&st->fmt, got, 128, 127, (128 * 3) & 255), "8-bit palettised surface blitted to the display format",
                            "index 128 became %06lx, palette says r 128 g 127 b %d", (unsigned long)got, (128 * 3) & 255);
                    } else {
                        res(st, 0, "8-bit palettised surface blitted to the display format", "%s", bt_hr(hr));
                    }
                } else {
                    res(st, 0, "8-bit palettised surface blitted to the display format", "Lock %s", bt_hr(hr));
                }
                IDirectDrawSurface7_Release(pal8);
            } else {
                res(st, 0, "palette: 256 entries on an 8-bit surface", "CreatePalette %s, 8-bit surface %s", bt_hr(pal ? 0 : hr), pal8 ? "made" : bt_hr(hr));
            }
            if (pal) IDirectDrawPalette_Release(pal);
        }
    }

    /* the sprite for the animation: 48x48, magenta is transparent */
    st->sprite = make_surface(st->dd, 48, 48, DDSCAPS_SYSTEMMEMORY, NULL, &hr);
    if (st->sprite) {
        DDCOLORKEY ck;
        RECT all = { 0, 0, 48, 48 }, ring = { 6, 6, 42, 42 }, core = { 14, 14, 34, 34 };
        DWORD magenta = pack(&st->fmt, 255, 0, 255);
        fill(st->sprite, &all, magenta);
        fill(st->sprite, &ring, pack(&st->fmt, 250, 210, 60));
        fill(st->sprite, &core, pack(&st->fmt, 220, 70, 40));
        ck.dwColorSpaceLowValue = ck.dwColorSpaceHighValue = magenta;
        IDirectDrawSurface7_SetColorKey(st->sprite, DDCKEY_SRCBLT, &ck);
    }
    return 1;
}

/* One frame of the animation into the work surface, then to the window. */
static void draw_frame(dd_state *st, double t, const char *title_line, double fps)
{
    HDC dc;
    int x, phase = (int)(t * 60.0);
    POINT org = { 0, 0 };
    RECT dst;
    HRESULT hr;

    for (x = 0; x < W / 16; x++) {   /* 40 stripes that scroll: colour fills (Blt), the cheapest thing DirectDraw does */
        RECT stripe;
        int c = (x * 7 + phase) & 255;
        stripe.left = x * 16; stripe.right = x * 16 + 16; stripe.top = 0; stripe.bottom = H;
        fill(st->work, &stripe, pack(&st->fmt, c, 60 + (c >> 2), 255 - c));
    }
    if (st->sprite) {
        int sx = (int)((W - 48) * (0.5 + 0.5 * sin(t * 1.7))), sy = (int)((H - 48) * (0.5 + 0.5 * sin(t * 2.3)));
        RECT at = { sx, sy, sx + 48, sy + 48 };
        IDirectDrawSurface7_Blt(st->work, &at, st->sprite, NULL, DDBLT_KEYSRC | DDBLT_WAIT, NULL);
    }
    if (SUCCEEDED(IDirectDrawSurface7_GetDC(st->work, &dc))) {
        int i;
        HGDIOBJ old = SelectObject(dc, GetStockObject(ANSI_FIXED_FONT));
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        TextOutA(dc, 8, 6, title_line, (int)strlen(title_line));
        for (i = 0; i < g_nlines; i++) {
            SetTextColor(dc, strncmp(g_lines[i], "PASS", 4) == 0 ? RGB(190, 255, 200) : RGB(255, 170, 170));
            TextOutA(dc, 8, 26 + 16 * i, g_lines[i], (int)strlen(g_lines[i]));
        }
        {
            char f[64];
            snprintf(f, sizeof f, "%.0f fps   F: full-screen test   Esc: close", fps);
            SetTextColor(dc, RGB(255, 240, 160));
            TextOutA(dc, 8, H - 22, f, (int)strlen(f));
        }
        SelectObject(dc, old);
        IDirectDrawSurface7_ReleaseDC(st->work, dc);
    }
    ClientToScreen(g_hwnd, &org);
    dst.left = org.x; dst.top = org.y; dst.right = org.x + W; dst.bottom = org.y + H;
    hr = IDirectDrawSurface7_Blt(st->primary, &dst, st->work, NULL, DDBLT_WAIT, NULL);
    if (hr == DDERR_SURFACELOST) {
        IDirectDrawSurface7_Restore(st->primary);
        IDirectDrawSurface7_Restore(st->work);
    }
}

/* ------------------------------------------------------------------ the full-screen part */

static void fullscreen_test(dd_state *st, HMODULE dll)
{
    createex_fn createex = (createex_fn)GetProcAddress(dll, "DirectDrawCreateEx");
    IDirectDraw7 *dd = NULL;
    IDirectDrawSurface7 *prim = NULL, *back = NULL;
    IDirectDrawPalette *pal = NULL;
    DDSURFACEDESC2 sd;
    DDSCAPS2 caps;
    PALETTEENTRY ent[256];
    HRESULT hr = E_FAIL, mh = E_FAIL;
    int i, flips = 0, ok = 0;
    double t0;
    DDSURFACEDESC2 now;

    bt_log("full-screen part: exclusive mode, 640x480x8, a flipping primary surface and a palette");
    release_all(st);   /* one DirectDraw object at a time: the windowed one goes while the mode changes */
    if (!createex || FAILED(hr = createex(NULL, (void **)&dd, &IID_IDirectDraw7, NULL)) || !dd) {
        bt_check(0, "full-screen: DirectDrawCreateEx", "%s", createex ? bt_hr(hr) : "no export");
        return;
    }
    hr = IDirectDraw7_SetCooperativeLevel(dd, g_hwnd, DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN | DDSCL_ALLOWREBOOT);
    bt_check(SUCCEEDED(hr), "full-screen: SetCooperativeLevel(EXCLUSIVE | FULLSCREEN)", "%s", bt_hr(hr));
    if (SUCCEEDED(hr)) {
        mh = IDirectDraw7_SetDisplayMode(dd, 640, 480, 8, 0, 0);
        bt_check(SUCCEEDED(mh), "full-screen: SetDisplayMode(640, 480, 8)", "%s", bt_hr(mh));
    }
    if (SUCCEEDED(mh)) {
        memset(&sd, 0, sizeof sd);
        sd.dwSize = sizeof sd;
        sd.dwFlags = DDSD_CAPS | DDSD_BACKBUFFERCOUNT;
        sd.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE | DDSCAPS_FLIP | DDSCAPS_COMPLEX;
        sd.dwBackBufferCount = 1;
        hr = IDirectDraw7_CreateSurface(dd, &sd, &prim, NULL);
        bt_check(SUCCEEDED(hr), "full-screen: flipping primary surface with a back buffer", "%s", bt_hr(hr));
        if (SUCCEEDED(hr)) {
            memset(&caps, 0, sizeof caps);
            caps.dwCaps = DDSCAPS_BACKBUFFER;
            hr = IDirectDrawSurface7_GetAttachedSurface(prim, &caps, &back);
            bt_check(SUCCEEDED(hr) && back, "full-screen: GetAttachedSurface(BACKBUFFER)", "%s", bt_hr(hr));
        }
        if (prim && back) {
            for (i = 0; i < 256; i++) { ent[i].peRed = (BYTE)i; ent[i].peGreen = (BYTE)((i * 2) & 255); ent[i].peBlue = (BYTE)(255 - i); ent[i].peFlags = 0; }
            hr = IDirectDraw7_CreatePalette(dd, DDPCAPS_8BIT | DDPCAPS_ALLOW256, ent, &pal, NULL);
            if (SUCCEEDED(hr)) hr = IDirectDrawSurface7_SetPalette(prim, pal);
            bt_check(SUCCEEDED(hr), "full-screen: palette on the primary surface", "%s", bt_hr(hr));
            t0 = bt_now();
            while (pump() && bt_now() - t0 < 3.0) {
                int shift = flips * 3;
                memset(&sd, 0, sizeof sd);
                sd.dwSize = sizeof sd;
                if (SUCCEEDED(IDirectDrawSurface7_Lock(back, NULL, &sd, DDLOCK_WAIT | DDLOCK_WRITEONLY, NULL))) {
                    int x, y;
                    for (y = 0; y < 480; y++)
                        for (x = 0; x < 640; x++) ((BYTE *)sd.lpSurface)[(size_t)y * (size_t)sd.lPitch + x] = (BYTE)(x / 3 + shift + (y > 460 ? 128 : 0));
                    IDirectDrawSurface7_Unlock(back, NULL);
                    hr = IDirectDrawSurface7_Flip(prim, NULL, DDFLIP_WAIT);
                    if (SUCCEEDED(hr)) flips++;
                    else if (hr == DDERR_SURFACELOST) IDirectDrawSurface7_Restore(prim);
                } else {
                    Sleep(10);
                }
            }
            memset(&now, 0, sizeof now);
            now.dwSize = sizeof now;
            hr = IDirectDraw7_GetDisplayMode(dd, &now);
            ok = flips >= 20 && SUCCEEDED(hr) && now.dwWidth == 640 && now.dwHeight == 480 && now.ddpfPixelFormat.dwRGBBitCount == 8;
            bt_check(ok, "full-screen: flips and the display mode read back", "%d flips in %.1f s, mode %lux%lux%lu", flips, bt_now() - t0, (unsigned long)now.dwWidth,
                     (unsigned long)now.dwHeight, (unsigned long)now.ddpfPixelFormat.dwRGBBitCount);
        }
    }
    if (pal) IDirectDrawPalette_Release(pal);
    if (back) IDirectDrawSurface7_Release(back);
    if (prim) IDirectDrawSurface7_Release(prim);
    hr = IDirectDraw7_RestoreDisplayMode(dd);
    bt_check(SUCCEEDED(hr), "full-screen: RestoreDisplayMode", "%s", bt_hr(hr));
    IDirectDraw7_SetCooperativeLevel(dd, g_hwnd, DDSCL_NORMAL);
    IDirectDraw7_Release(dd);
    bt_log("full-screen part done");
}

/* ------------------------------------------------------------------ main */

/* 1 when the module's version resource names "cnc-ddraw" (UTF-16), the DirectDraw replacement env.MADEIRA_DDRAW = cnc links. */
static int is_cnc_ddraw(HMODULE dll)
{
    static const WCHAR tag[] = L"cnc-ddraw";
    HRSRC res = FindResourceW(dll, MAKEINTRESOURCEW(1), (LPCWSTR)RT_VERSION);
    HGLOBAL mem = res ? LoadResource(dll, res) : NULL;
    const BYTE *p = mem ? (const BYTE *)LockResource(mem) : NULL;
    DWORD n = res ? SizeofResource(dll, res) : 0, i;

    if (!p) return 0;
    for (i = 0; i + sizeof tag <= n; i++)
        if (memcmp(p + i, tag, sizeof tag - sizeof(WCHAR)) == 0) return 1;
    return 0;
}

static void route_hint(int is_cnc)
{
    if (!is_cnc)
        bt_log("hint: Wine's own DirectDraw draws with OpenGL (wined3d), which iOS does not have. env.MADEIRA_DDRAW = cnc in the settings of the session links "
               "cnc-ddraw instead, whose Direct3D 9 renderer draws through DXMT; a 3D DirectDraw (Direct3D 7) game is not covered");
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    HMODULE dll;
    dd_state st;
    char title[128], head[96];
    double t0, last, frame_t;
    unsigned frames = 0, shown = 0;
    int reported = 0, fs_done = 0, cnc = 0;

    (void)inst; (void)prev; (void)cmd; (void)show;
    bt_init("ddraw");
    snprintf(title, sizeof title, "BCD DirectDraw test (%d-bit)", BT_BITS);
    g_hwnd = make_window(title);
    if (!g_hwnd) { bt_check(0, "window", "could not be created"); bt_result(); MessageBoxA(NULL, "The window could not be created.", "BCD DirectDraw test", MB_OK | MB_ICONERROR); return 1; }
    dll = LoadLibraryA("ddraw.dll");
    if (!dll) {
        bt_check(0, "ddraw.dll", "not available (LoadLibrary %lu)", GetLastError());
        bt_result();
        MessageBoxA(NULL, "ddraw.dll is not available in this session.", "BCD DirectDraw test", MB_OK | MB_ICONERROR);
        return 1;
    }
    {
        char path[MAX_PATH], sw[32];
        path[0] = 0;
        GetModuleFileNameA(dll, path, sizeof path);
        sw[0] = 0;
        GetEnvironmentVariableA("MADEIRA_DDRAW", sw, sizeof sw);
        cnc = is_cnc_ddraw(dll);
        bt_log("ddraw.dll is %s (%s); env.MADEIRA_DDRAW = %s", path, cnc ? "cnc-ddraw" : "not cnc-ddraw: Wine's own", sw[0] ? sw : "(not set)");
    }
    if (!open_windowed(&st, dll, 1)) {
        route_hint(cnc);
        bt_result();
        MessageBoxA(NULL, "DirectDraw could not draw in this session. The log has the details.\n\nBCD has no OpenGL, which Wine's own DirectDraw draws with.",
                    "BCD DirectDraw test", MB_OK | MB_ICONERROR);
        release_all(&st);
        return 1;
    }
    snprintf(head, sizeof head, "%d of %d checks so far", bt_g.checks - bt_g.fails, bt_g.checks);

    t0 = last = bt_now();
    while (pump()) {
        double now = bt_now();
        char line[128];
        frame_t = now - t0;
        snprintf(line, sizeof line, "BCD DirectDraw test (%d-bit)  %s", BT_BITS, bt_g.head[0] ? bt_g.head : head);
        draw_frame(&st, frame_t, line, now - last > 0 ? 1.0 / (now - last) : 0);
        last = now;
        frames++;
        if (!reported && frame_t >= 2.0) {
            int ok;
            reported = 1;
            ok = frames >= 30;
            bt_check(ok, "animation: sprite under a colour key over a gradient, blitted to the window", "%u frames in %.1f s (%.0f fps)", frames, frame_t, frames / frame_t);
            bt_headline("%s, display %s, animation %.0f fps", cnc ? "cnc-ddraw" : "Wine's ddraw", g_disp, frames / frame_t);
            bt_result();
            snprintf(title, sizeof title, "BCD DirectDraw test (%d-bit) - %s", BT_BITS, bt_g.head);
            SetWindowTextA(g_hwnd, title);
            bt_log("press F in the window for the full-screen part (it changes the display mode), Esc to close");
        }
        if (g_key == 'F' || g_tap) {
            g_key = 0;
            g_tap = 0;
            if (reported && !fs_done) {
                fs_done = 1;
                fullscreen_test(&st, dll);
                bt_result();
                snprintf(title, sizeof title, "BCD DirectDraw test (%d-bit) - %s (incl. full-screen)", BT_BITS, bt_g.head);
                SetWindowTextA(g_hwnd, title);
                if (pump() && !open_windowed(&st, dll, 0)) { bt_log("the windowed surfaces could not be made again; ending"); break; }
                t0 = bt_now();
            }
        }
        shown++;
        Sleep(8);
    }
    bt_log("the window was closed after %u frames", shown);
    release_all(&st);
    return 0;
}
