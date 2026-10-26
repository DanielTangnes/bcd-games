// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's resolution and full-screen test (round 602): what a game finds out about the screen and what happens when it changes
// it. x86-64 Windows. Three parts; the first two run by themselves, the third changes the display and waits for a button:
//
//   1. The display: the current mode and every mode EnumDisplaySettingsEx lists (how many, which resolutions, which colour
//      depths and rates), the screen metrics, the monitors, the work area and the DPI, with a check that the current mode and
//      GetSystemMetrics agree.
//   2. The window: resized from the program to 640x480, 800x600 and 1024x768 (the size that arrives in WM_SIZE and the client
//      area GetClientRect gives are compared with what was asked), maximised and restored, and made a borderless full-screen
//      window (WS_POPUP over the whole screen, the way many games go "full screen") and restored.
//   3. Buttons (they change the display mode for a few seconds and put it back; press M, F or A, or tap a button):
//        M  a mode change and back: ChangeDisplaySettingsEx with CDS_TEST, then for real (CDS_FULLSCREEN) to a smaller mode,
//           a wait for WM_DISPLAYCHANGE, the new size read back two ways, then the original mode restored and read back;
//        F  DXGI full screen: a Direct3D 11 swap chain in a window, SetFullscreenState(TRUE), the state and the back-buffer
//           size read back, ResizeBuffers, frames presented, SetFullscreenState(FALSE), and a window resize followed by
//           ResizeBuffers to the new size;
//        A  both.
//
// Every line is PASS or FAIL with the numbers, in the window and in the session log ("[bcd-test] resolution (64-bit): ...").

#define COBJMACROS
#include "bcdtest.h"
#include <d3d11.h>

#define MAXRES 64

typedef HRESULT (WINAPI *create_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *, UINT, UINT,
                                    const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *,
                                    ID3D11DeviceContext **);

static int g_sizes, g_dispchanges, g_last_w, g_last_h;
static int g_state_display, g_state_window, g_state_mode, g_state_dxgi;   /* 0 not run, 1 passed, 2 failed */
static char g_display_line[160] = "";

/* Counts WM_SIZE and WM_DISPLAYCHANGE; handles nothing itself. */
static int msg_hook(bt_panel *p, UINT m, WPARAM w, LPARAM l, LRESULT *res)
{
    (void)p; (void)w; (void)res;
    if (m == WM_SIZE) { g_sizes++; g_last_w = LOWORD(l); g_last_h = HIWORD(l); }
    if (m == WM_DISPLAYCHANGE) g_dispchanges++;
    return 0;
}

typedef struct { int w, h, bpp, hz, count; } res_t;

static int cmp_res(const void *a, const void *b)
{
    const res_t *x = (const res_t *)a, *y = (const res_t *)b;
    return (y->w * y->h) - (x->w * x->h);
}

static DEVMODEA current_mode(void)
{
    DEVMODEA dm;
    memset(&dm, 0, sizeof dm);
    dm.dmSize = sizeof dm;
    EnumDisplaySettingsExA(NULL, ENUM_CURRENT_SETTINGS, &dm, 0);
    return dm;
}

static const char *cds_name(LONG r)
{
    switch (r) {
    case DISP_CHANGE_SUCCESSFUL: return "SUCCESSFUL";
    case DISP_CHANGE_RESTART: return "RESTART";
    case DISP_CHANGE_FAILED: return "FAILED";
    case DISP_CHANGE_BADMODE: return "BADMODE";
    case DISP_CHANGE_NOTUPDATED: return "NOTUPDATED";
    case DISP_CHANGE_BADFLAGS: return "BADFLAGS";
    case DISP_CHANGE_BADPARAM: return "BADPARAM";
    }
    return "?";
}

static BOOL CALLBACK mon_cb(HMONITOR m, HDC dc, RECT *r, LPARAM l)
{
    (void)m; (void)dc; (void)r;
    (*(int *)l)++;
    return TRUE;
}

/* ------------------------------------------------------------------ 1. the display */

static res_t g_res[MAXRES];
static int g_nres, g_modes;

static void part_display(bt_panel *pn)
{
    DEVMODEA dm = current_mode(), e;
    int i, k, found_current = 0, monitors = 0, depth_mask = 0, shown = 0;
    char list[400];
    MONITORINFO mi;
    HDC dc;
    int dpi = 0;
    unsigned (WINAPI *get_dpi)(void) = (unsigned (WINAPI *)(void))GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForSystem");

    bt_note(pn, BT_HEAD, "== 1. the display ==");
    bt_report(pn, dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0, "current mode", "%lux%lu, %lu bit, %lu Hz, position %ld,%ld", (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight,
              (unsigned long)dm.dmBitsPerPel, (unsigned long)dm.dmDisplayFrequency, (long)dm.dmPosition.x, (long)dm.dmPosition.y);

    g_nres = g_modes = 0;
    for (i = 0;; i++) {
        memset(&e, 0, sizeof e);
        e.dmSize = sizeof e;
        if (!EnumDisplaySettingsExA(NULL, (DWORD)i, &e, 0)) break;
        g_modes++;
        if (e.dmPelsWidth == dm.dmPelsWidth && e.dmPelsHeight == dm.dmPelsHeight && e.dmBitsPerPel == dm.dmBitsPerPel) found_current = 1;
        if (e.dmBitsPerPel == 8) depth_mask |= 1;
        if (e.dmBitsPerPel == 16) depth_mask |= 2;
        if (e.dmBitsPerPel == 32) depth_mask |= 4;
        for (k = 0; k < g_nres; k++)
            if (g_res[k].w == (int)e.dmPelsWidth && g_res[k].h == (int)e.dmPelsHeight) break;
        if (k == g_nres && g_nres < MAXRES) {
            g_res[k].w = (int)e.dmPelsWidth; g_res[k].h = (int)e.dmPelsHeight; g_res[k].bpp = 0; g_res[k].hz = 0; g_res[k].count = 0;
            g_nres++;
        }
        if (k < g_nres) {
            g_res[k].count++;
            if ((int)e.dmBitsPerPel > g_res[k].bpp) g_res[k].bpp = (int)e.dmBitsPerPel;
            if ((int)e.dmDisplayFrequency > g_res[k].hz) g_res[k].hz = (int)e.dmDisplayFrequency;
        }
        if (i > 4000) break;
    }
    qsort(g_res, (size_t)g_nres, sizeof g_res[0], cmp_res);
    snprintf(g_display_line, sizeof g_display_line, "display %lux%lu %lu-bit %lu Hz, %d modes, %d resolutions", (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight,
             (unsigned long)dm.dmBitsPerPel, (unsigned long)dm.dmDisplayFrequency, g_modes, g_nres);
    bt_report(pn, g_modes > 0 && found_current, "EnumDisplaySettingsEx", "%d modes, %d resolutions; colour depths: %s%s%s; the current mode %s the list", g_modes, g_nres,
              (depth_mask & 1) ? "8 " : "", (depth_mask & 2) ? "16 " : "", (depth_mask & 4) ? "32" : "", found_current ? "is in" : "is NOT in");
    list[0] = 0;
    for (k = 0; k < g_nres && shown < 10; k++, shown++) {
        char one[40];
        snprintf(one, sizeof one, "%s%dx%d@%d", shown ? ", " : "", g_res[k].w, g_res[k].h, g_res[k].hz);
        if (strlen(list) + strlen(one) < sizeof list) strcat(list, one);
    }
    bt_note(pn, BT_INFO, "  largest resolutions: %s%s", list, g_nres > shown ? ", ..." : "");

    {
        int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
        bt_report(pn, sw == (int)dm.dmPelsWidth && sh == (int)dm.dmPelsHeight, "GetSystemMetrics agrees with the mode", "SM_CXSCREEN x SM_CYSCREEN = %dx%d, mode %lux%lu, virtual screen %dx%d",
                  sw, sh, (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight, GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
    }
    EnumDisplayMonitors(NULL, NULL, mon_cb, (LPARAM)&monitors);
    memset(&mi, 0, sizeof mi);
    mi.cbSize = sizeof mi;
    {
        HMONITOR hm = MonitorFromWindow(pn->hwnd, MONITOR_DEFAULTTOPRIMARY);
        BOOL ok = hm && GetMonitorInfoA(hm, &mi);
        bt_report(pn, monitors >= 1 && ok, "monitors", "%d monitor(s); primary %ld,%ld to %ld,%ld, work area %ld,%ld to %ld,%ld", monitors, (long)mi.rcMonitor.left, (long)mi.rcMonitor.top,
                  (long)mi.rcMonitor.right, (long)mi.rcMonitor.bottom, (long)mi.rcWork.left, (long)mi.rcWork.top, (long)mi.rcWork.right, (long)mi.rcWork.bottom);
    }
    dc = GetDC(NULL);
    if (dc) { dpi = GetDeviceCaps(dc, LOGPIXELSX); ReleaseDC(NULL, dc); }
    bt_note(pn, BT_INFO, "  DPI: %d (GetDeviceCaps), system DPI %u; colour bits %d", dpi, get_dpi ? get_dpi() : 0, (int)dm.dmBitsPerPel);
}

/* ------------------------------------------------------------------ 2. the window */

static void settle(bt_panel *pn) { bt_sleep(pn, 350); }

static void part_window(bt_panel *pn)
{
    static const int sizes[3][2] = { { 640, 480 }, { 800, 600 }, { 1024, 768 } };
    DEVMODEA dm = current_mode();
    RECT cr, wr;
    int i;
    LONG style;
    HWND h = pn->hwnd;
    RECT orig;
    WINDOWPLACEMENT wp;

    bt_note(pn, BT_HEAD, "== 2. the window ==");
    GetWindowRect(h, &orig);
    for (i = 0; i < 3; i++) {
        RECT want = { 0, 0, sizes[i][0], sizes[i][1] };
        int before = g_sizes;
        if (sizes[i][0] > (int)dm.dmPelsWidth || sizes[i][1] > (int)dm.dmPelsHeight) {
            bt_note(pn, BT_INFO, "  %dx%d is larger than the screen (%lux%lu): skipped", sizes[i][0], sizes[i][1], (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight);
            continue;
        }
        AdjustWindowRect(&want, (DWORD)GetWindowLongA(h, GWL_STYLE), FALSE);
        SetWindowPos(h, NULL, 0, 0, want.right - want.left, want.bottom - want.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        settle(pn);
        GetClientRect(h, &cr);
        bt_report(pn, cr.right == sizes[i][0] && cr.bottom == sizes[i][1], "window resize", "asked for a %dx%d client area, GetClientRect says %ldx%ld, WM_SIZE %d time(s) (last %dx%d)",
                  sizes[i][0], sizes[i][1], (long)cr.right, (long)cr.bottom, g_sizes - before, g_last_w, g_last_h);
    }
    ShowWindow(h, SW_MAXIMIZE);
    settle(pn);
    GetClientRect(h, &cr);
    GetWindowRect(h, &wr);
    memset(&wp, 0, sizeof wp);
    wp.length = sizeof wp;
    GetWindowPlacement(h, &wp);
    bt_report(pn, wp.showCmd == SW_SHOWMAXIMIZED && cr.right >= (LONG)dm.dmPelsWidth * 9 / 10, "maximise", "state %s, client %ldx%ld, window %ldx%ld on a %lux%lu screen",
              wp.showCmd == SW_SHOWMAXIMIZED ? "maximised" : "NOT maximised", (long)cr.right, (long)cr.bottom, (long)(wr.right - wr.left), (long)(wr.bottom - wr.top),
              (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight);
    ShowWindow(h, SW_RESTORE);
    settle(pn);

    /* a borderless full-screen window, the way many games make "full screen" */
    style = GetWindowLongA(h, GWL_STYLE);
    SetWindowLongA(h, GWL_STYLE, (style & ~(LONG)WS_OVERLAPPEDWINDOW) | (LONG)WS_POPUP);
    SetWindowPos(h, HWND_TOP, 0, 0, (int)dm.dmPelsWidth, (int)dm.dmPelsHeight, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    settle(pn);
    GetClientRect(h, &cr);
    bt_report(pn, cr.right == (LONG)dm.dmPelsWidth && cr.bottom == (LONG)dm.dmPelsHeight, "borderless full-screen window", "WS_POPUP over the screen: client %ldx%ld, screen %lux%lu",
              (long)cr.right, (long)cr.bottom, (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight);
    SetWindowLongA(h, GWL_STYLE, style);
    SetWindowPos(h, HWND_NOTOPMOST, orig.left, orig.top, orig.right - orig.left, orig.bottom - orig.top, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    settle(pn);
    GetClientRect(h, &cr);
    bt_report(pn, (GetWindowLongA(h, GWL_STYLE) & WS_CAPTION) == WS_CAPTION, "window restored", "caption back, client %ldx%ld", (long)cr.right, (long)cr.bottom);
}

/* ------------------------------------------------------------------ 3a. a mode change and back */

static void test_mode_change(bt_panel *pn)
{
    DEVMODEA orig = current_mode(), target, e;
    LONG r;
    int i, have = 0, before_change;
    int sw, sh;

    bt_note(pn, BT_HEAD, "== 3a. mode change and back ==");
    memset(&target, 0, sizeof target);
    /* a smaller mode of the same depth: 800x600 first, then 1024x768, then 640x480, then any; the same rate is preferred */
    {
        int best = -1;
        for (i = 0;; i++) {
            int score;
            memset(&e, 0, sizeof e);
            e.dmSize = sizeof e;
            if (!EnumDisplaySettingsExA(NULL, (DWORD)i, &e, 0)) break;
            if (e.dmBitsPerPel != orig.dmBitsPerPel || e.dmPelsWidth >= orig.dmPelsWidth || e.dmPelsHeight >= orig.dmPelsHeight) continue;
            score = (e.dmPelsWidth == 800 && e.dmPelsHeight == 600) ? 3 : (e.dmPelsWidth == 1024 && e.dmPelsHeight == 768) ? 2 : (e.dmPelsWidth == 640 && e.dmPelsHeight == 480) ? 1 : 0;
            if (e.dmDisplayFrequency == orig.dmDisplayFrequency) score += 10;
            if (score > best) { best = score; target = e; }
            if (i > 4000) break;
        }
        have = best >= 0;
    }
    if (!have) {
        bt_report(pn, 0, "a smaller mode to change to", "none in the list (current %lux%lu)", (unsigned long)orig.dmPelsWidth, (unsigned long)orig.dmPelsHeight);
        return;
    }
    target.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | (target.dmDisplayFrequency ? DM_DISPLAYFREQUENCY : 0);
    r = ChangeDisplaySettingsExA(NULL, &target, NULL, CDS_TEST, NULL);
    bt_report(pn, r == DISP_CHANGE_SUCCESSFUL, "CDS_TEST for the new mode", "%lux%lu: %s (%ld)", (unsigned long)target.dmPelsWidth, (unsigned long)target.dmPelsHeight, cds_name(r), (long)r);
    if (r != DISP_CHANGE_SUCCESSFUL) return;

    before_change = g_dispchanges;
    r = ChangeDisplaySettingsExA(NULL, &target, NULL, CDS_FULLSCREEN, NULL);
    bt_report(pn, r == DISP_CHANGE_SUCCESSFUL, "ChangeDisplaySettingsEx(CDS_FULLSCREEN)", "%lux%lu: %s (%ld)", (unsigned long)target.dmPelsWidth, (unsigned long)target.dmPelsHeight, cds_name(r), (long)r);
    if (r == DISP_CHANGE_SUCCESSFUL) {
        DEVMODEA now;
        bt_sleep(pn, 1500);
        now = current_mode();
        sw = GetSystemMetrics(SM_CXSCREEN);
        sh = GetSystemMetrics(SM_CYSCREEN);
        bt_report(pn, now.dmPelsWidth == target.dmPelsWidth && now.dmPelsHeight == target.dmPelsHeight, "the new mode is the current mode", "EnumDisplaySettingsEx says %lux%lu, wanted %lux%lu",
                  (unsigned long)now.dmPelsWidth, (unsigned long)now.dmPelsHeight, (unsigned long)target.dmPelsWidth, (unsigned long)target.dmPelsHeight);
        bt_report(pn, sw == (int)target.dmPelsWidth && sh == (int)target.dmPelsHeight, "GetSystemMetrics follows", "SM_CXSCREEN x SM_CYSCREEN = %dx%d", sw, sh);
        bt_report(pn, g_dispchanges > before_change, "WM_DISPLAYCHANGE arrived", "%d message(s) since the change", g_dispchanges - before_change);
    }
    before_change = g_dispchanges;
    r = ChangeDisplaySettingsExA(NULL, NULL, NULL, 0, NULL);   /* back to the registry's mode */
    bt_report(pn, r == DISP_CHANGE_SUCCESSFUL, "restore (ChangeDisplaySettingsEx with no mode)", "%s (%ld)", cds_name(r), (long)r);
    bt_sleep(pn, 1500);
    {
        DEVMODEA now = current_mode();
        bt_report(pn, now.dmPelsWidth == orig.dmPelsWidth && now.dmPelsHeight == orig.dmPelsHeight, "the original mode is back", "now %lux%lu, was %lux%lu, %d WM_DISPLAYCHANGE",
                  (unsigned long)now.dmPelsWidth, (unsigned long)now.dmPelsHeight, (unsigned long)orig.dmPelsWidth, (unsigned long)orig.dmPelsHeight, g_dispchanges - before_change);
    }
}

/* ------------------------------------------------------------------ 3b. DXGI full screen */

static LRESULT CALLBACK gfx_proc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_CLOSE) { DestroyWindow(h); return 0; }
    if (m == WM_ERASEBKGND) return 1;
    return DefWindowProcA(h, m, w, l);
}

static void present_frames(bt_panel *pn, IDXGISwapChain *sc, ID3D11DeviceContext *ctx, ID3D11RenderTargetView **rtv, ID3D11Device *dev, int n, const float *color, int *fails)
{
    int i;
    (void)dev;
    for (i = 0; i < n; i++) {
        HRESULT hr;
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, *rtv, color);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        if (FAILED(hr)) (*fails)++;
        if (!bt_pump(pn)) return;
        Sleep(8);
    }
}

static int make_rtv(IDXGISwapChain *sc, ID3D11Device *dev, ID3D11RenderTargetView **rtv)
{
    ID3D11Texture2D *back = NULL;
    HRESULT hr = IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back);
    if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, rtv);
    if (back) ID3D11Texture2D_Release(back);
    return SUCCEEDED(hr);
}

static void test_dxgi(bt_panel *pn)
{
    static const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
    static const float red[4] = { 0.7f, 0.1f, 0.1f, 1 }, green[4] = { 0.1f, 0.6f, 0.2f, 1 }, blue[4] = { 0.1f, 0.2f, 0.8f, 1 };
    HMODULE dll = LoadLibraryA("d3d11.dll");
    create_fn create = dll ? (create_fn)GetProcAddress(dll, "D3D11CreateDeviceAndSwapChain") : NULL;
    WNDCLASSA wc;
    HWND win;
    RECT r = { 0, 0, 640, 480 };
    DXGI_SWAP_CHAIN_DESC sd, got;
    IDXGISwapChain *sc = NULL;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr;
    BOOL fs = FALSE;
    IDXGIOutput *out = NULL;
    int fails = 0;
    RECT cr;

    bt_note(pn, BT_HEAD, "== 3b. DXGI full screen ==");
    if (!create) { bt_report(pn, 0, "d3d11.dll", "not available"); return; }
    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = gfx_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "BCDResolutionGfx";
    RegisterClassA(&wc);
    AdjustWindowRect(&r, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME, FALSE);
    win = CreateWindowExA(0, wc.lpszClassName, "BCD DXGI full-screen test", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_VISIBLE, 40, 40,
                          r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
    if (!win) { bt_report(pn, 0, "test window", "could not be created"); return; }

    memset(&sd, 0, sizeof sd);
    sd.BufferDesc.Width = 640;
    sd.BufferDesc.Height = 480;
    sd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.OutputWindow = win;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
    hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, levels, 3, D3D11_SDK_VERSION, &sd, &sc, &dev, &level, &ctx);
    if (!bt_report(pn, SUCCEEDED(hr) && sc, "D3D11CreateDeviceAndSwapChain (windowed, ALLOW_MODE_SWITCH)", "%s, feature level %#x", bt_hr(hr), (unsigned)level)) { DestroyWindow(win); return; }
    if (!make_rtv(sc, dev, &rtv)) { bt_report(pn, 0, "render target view", "GetBuffer or CreateRenderTargetView failed"); goto done; }

    present_frames(pn, sc, ctx, &rtv, dev, 20, red, &fails);
    bt_report(pn, fails == 0, "windowed: 20 frames presented", "%d Present call(s) failed", fails);

    /* into full screen */
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
    ID3D11RenderTargetView_Release(rtv);
    rtv = NULL;
    hr = IDXGISwapChain_SetFullscreenState(sc, TRUE, NULL);
    bt_report(pn, SUCCEEDED(hr), "SetFullscreenState(TRUE)", "%s", bt_hr(hr));
    if (SUCCEEDED(hr)) {
        int resized;
        fs = FALSE;
        out = NULL;
        hr = IDXGISwapChain_GetFullscreenState(sc, &fs, &out);
        bt_report(pn, SUCCEEDED(hr) && fs, "GetFullscreenState says full screen", "%s, state %s, output %s", bt_hr(hr), fs ? "full screen" : "windowed", out ? "given" : "none");
        if (out) { IDXGIOutput_Release(out); out = NULL; }
        bt_sleep(pn, 400);
        {
            DEVMODEA dm = current_mode();
            hr = IDXGISwapChain_ResizeBuffers(sc, 0, 0, 0, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH);
            memset(&got, 0, sizeof got);
            IDXGISwapChain_GetDesc(sc, &got);
            resized = SUCCEEDED(hr);
            bt_report(pn, resized, "ResizeBuffers in full screen", "%s, back buffer %ux%u, display mode %lux%lu", bt_hr(hr), got.BufferDesc.Width, got.BufferDesc.Height,
                      (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight);
        }
        if (make_rtv(sc, dev, &rtv)) {
            fails = 0;
            present_frames(pn, sc, ctx, &rtv, dev, 40, green, &fails);
            bt_report(pn, fails == 0, "full screen: 40 frames presented", "%d Present call(s) failed", fails);
            ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
            ID3D11RenderTargetView_Release(rtv);
            rtv = NULL;
        }
        hr = IDXGISwapChain_SetFullscreenState(sc, FALSE, NULL);
        bt_report(pn, SUCCEEDED(hr), "SetFullscreenState(FALSE)", "%s", bt_hr(hr));
        fs = TRUE;
        IDXGISwapChain_GetFullscreenState(sc, &fs, NULL);
        bt_report(pn, !fs, "GetFullscreenState says windowed again", "state %s", fs ? "full screen" : "windowed");
        bt_sleep(pn, 400);
        IDXGISwapChain_ResizeBuffers(sc, 0, 0, 0, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH);
        make_rtv(sc, dev, &rtv);
    } else if (!rtv) {
        make_rtv(sc, dev, &rtv);
    }

    /* a window resize followed by ResizeBuffers, the way a windowed game follows its window */
    if (rtv) {
        RECT want = { 0, 0, 800, 600 };
        DEVMODEA dm = current_mode();
        if (dm.dmPelsWidth >= 900 && dm.dmPelsHeight >= 700) {
            ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
            ID3D11RenderTargetView_Release(rtv);
            rtv = NULL;
            AdjustWindowRect(&want, (DWORD)GetWindowLongA(win, GWL_STYLE), FALSE);
            SetWindowPos(win, NULL, 0, 0, want.right - want.left, want.bottom - want.top, SWP_NOMOVE | SWP_NOZORDER);
            bt_sleep(pn, 300);
            GetClientRect(win, &cr);
            hr = IDXGISwapChain_ResizeBuffers(sc, 0, 0, 0, DXGI_FORMAT_UNKNOWN, DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH);
            memset(&got, 0, sizeof got);
            IDXGISwapChain_GetDesc(sc, &got);
            bt_report(pn, SUCCEEDED(hr) && got.BufferDesc.Width == (UINT)cr.right && got.BufferDesc.Height == (UINT)cr.bottom, "window resize, then ResizeBuffers(0, 0)",
                      "client %ldx%ld, back buffer %ux%u, %s", (long)cr.right, (long)cr.bottom, got.BufferDesc.Width, got.BufferDesc.Height, bt_hr(hr));
            if (make_rtv(sc, dev, &rtv)) {
                fails = 0;
                present_frames(pn, sc, ctx, &rtv, dev, 20, blue, &fails);
                bt_report(pn, fails == 0, "after the resize: 20 frames presented", "%d Present call(s) failed", fails);
            }
        } else {
            bt_note(pn, BT_INFO, "  the screen (%lux%lu) is too small for the 800x600 window resize: skipped", (unsigned long)dm.dmPelsWidth, (unsigned long)dm.dmPelsHeight);
        }
    }
done:
    if (ctx) { ID3D11DeviceContext_ClearState(ctx); }
    if (rtv) ID3D11RenderTargetView_Release(rtv);
    if (sc) { IDXGISwapChain_SetFullscreenState(sc, FALSE, NULL); IDXGISwapChain_Release(sc); }
    if (ctx) ID3D11DeviceContext_Release(ctx);
    if (dev) ID3D11Device_Release(dev);
    DestroyWindow(win);
    bt_pump(pn);
}

/* ------------------------------------------------------------------ main */

static const char *state_name(int s) { return s == 1 ? "passed" : s == 2 ? "FAILED" : "not run"; }

static void finish(bt_panel *pn)
{
    bt_headline("%s; display part %s; window part %s; mode change %s; DXGI full screen %s", g_display_line, state_name(g_state_display), state_name(g_state_window), state_name(g_state_mode),
                state_name(g_state_dxgi));
    bt_result();
    bt_panel_title(pn, "resolution test", bt_g.head);
    bt_panel_line(pn, bt_g.fails ? BT_FAIL : BT_PASS, "RESULT %s: %d of %d checks passed. M: mode change, F: DXGI full screen, A: both. Send Log to keep this.", bt_g.fails ? "FAIL" : "PASS",
                  bt_g.checks - bt_g.fails, bt_g.checks);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    bt_panel *pn;
    int id;

    (void)inst; (void)prev; (void)cmd; (void)show;
    bt_init("resolution");
    pn = bt_panel_new("resolution test", 760, 560);
    if (!pn) { bt_check(0, "window", "could not be created"); bt_result(); return 1; }
    pn->msg_hook = msg_hook;
    bt_panel_button(pn, 'M', "M: mode change");
    bt_panel_button(pn, 'F', "F: DXGI full screen");
    bt_panel_button(pn, 'A', "A: both");
    bt_panel_button(pn, 'Q', "Close");

    {
        int before = bt_g.fails;
        part_display(pn);
        g_state_display = bt_g.fails == before ? 1 : 2;
        before = bt_g.fails;
        part_window(pn);
        g_state_window = bt_g.fails == before ? 1 : 2;
    }
    finish(pn);
    bt_note(pn, BT_WARN, "M, F and A change the display mode for a few seconds and put it back.");
    while ((id = bt_wait_click(pn)) != 0) {
        if (id == 'Q') { PostMessageA(pn->hwnd, WM_CLOSE, 0, 0); continue; }
        if (id == 'M' || id == 'A') { int before = bt_g.fails; test_mode_change(pn); g_state_mode = bt_g.fails == before ? 1 : 2; }
        if (id == 'F' || id == 'A') { int before = bt_g.fails; test_dxgi(pn); g_state_dxgi = bt_g.fails == before ? 1 : 2; }
        if (id == 'M' || id == 'F' || id == 'A') finish(pn);
    }
    return 0;
}
