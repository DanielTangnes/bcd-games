// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// bcdtest.h: what BCD's graphics, sound, video and input test programs share (round 602; the Start menu's "BCD Tests"
// folder). Plain C for Windows (x86-64 or x86), built with llvm-mingw by tools/build-dx-tests.sh.
//
//  - The log. Every line goes to stderr in one WriteFile, "[bcd-test] <program> (<bits>-bit): <text>"; this is the same
//    way the Direct3D cubes' "[dx-test]" lines (dxtest.h) and tests/x86/hello-x86.c reach BCD's session log: Wine
//    hands a Windows program's standard error to the host process's stderr, which the app records. The same lines
//    go to <temp>\bcd-test.log as well, a regular file, because the session log also mirrors the error-like lines of
//    a program's own *.log files as "[guest-log]" (tools/patch-wine-guest-log.py): the second way in when a program
//    started from the Start menu has no standard error.
//  - The verdicts. bt_check() writes "PASS <what>: <numbers>" or "FAIL <what>: <numbers>" and counts them; bt_result()
//    writes the one line "RESULT PASS|FAIL <n> checks" that a person (and a script) looks for.
//  - A crash is a line too: an unhandled exception is logged with its code and address, then the program ends.
//  - A text window (bt_panel): lines coloured by kind, a scroll bar, big buttons for a touch screen, and hooks for a
//    program that draws its own picture (the controller and input tests).
//
// Where the lines can go. A program started from the Start menu is started by Wine's shell32 with CREATE_NEW_CONSOLE (shlexec.c: no
// SEE_MASK_NO_CONSOLE), so kernelbase does not hand it the parent's standard handles (process.c, create_process_params) and, being a GUI
// program, it gets no console: GetStdHandle(STD_ERROR_HANDLE) is NULL and the stderr line is lost. The .log file is the way in then: the
// [guest-log] mirror (tools/patch-wine-guest-log.py) copies a line of a *.log file into the session log when it has one of a few words
// (error, fail, exception, unsupported, gpu, driver, adapter, graphics, monitor, display, nvapi, nvidia) and only the first 64 such lines
// of the whole session (env.MADEIRA_GUEST_LOG = all: every line, 400 of them). So every FAIL line has "FAIL", the CRASH line says
// "exception", and the RESULT line always says how many checks "failed" and carries the program's headline numbers: that line, the one
// to read, reaches the log whatever the mirror's mode is.
//
// Everything is static inline so that a program that does not use a function does not pay for it, and the host check
// (tests/host/check-bcd-tests.py) can compile the pure parts without Windows (bcdstats.h).

#ifndef BCD_TEST_H
#define BCD_TEST_H

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BT_BITS ((int)(sizeof(void *) * 8))

/* ------------------------------------------------------------------ the log and the verdicts */

typedef struct {
    const char *name;     /* "sound" */
    int checks, fails;
    HANDLE file;          /* <temp>\bcd-test.log, or INVALID_HANDLE_VALUE */
    char head[96];        /* "PASS 7/7" once bt_result() ran, for a window title */
    char headline[260];   /* the numbers that go on the RESULT line (bt_headline) */
} bt_state_t;

static bt_state_t bt_g = { "test", 0, 0, NULL, "", "" };

static inline double bt_now(void)
{
    LARGE_INTEGER f, t;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)f.QuadPart;
}

/* One line, newline included (n bytes), to stderr and the file. */
static inline void bt_emit(const char *line, int n)
{
    DWORD w = 0;
    HANDLE e = GetStdHandle(STD_ERROR_HANDLE);
    if (e && e != INVALID_HANDLE_VALUE) WriteFile(e, line, (DWORD)n, &w, NULL);
    if (bt_g.file && bt_g.file != INVALID_HANDLE_VALUE) WriteFile(bt_g.file, line, (DWORD)n, &w, NULL);
}

static inline void bt_vlog(const char *fmt, va_list ap)
{
    char line[640];
    int n = snprintf(line, sizeof line, "[bcd-test] %s (%d-bit): ", bt_g.name, BT_BITS);
    if (n < 0) n = 0;
    {
        int m = vsnprintf(line + n, sizeof line - (size_t)n - 2, fmt, ap);
        if (m < 0) m = 0;
        n += m;
    }
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    bt_emit(line, n);
}

static inline void bt_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    bt_vlog(fmt, ap);
    va_end(ap);
}

/* A check that counts: "PASS what: details" or "FAIL what: details". Returns ok. */
static inline int bt_check(int ok, const char *what, const char *fmt, ...)
{
    char details[480];
    va_list ap;

    details[0] = 0;
    if (fmt) {
        va_start(ap, fmt);
        vsnprintf(details, sizeof details, fmt, ap);
        va_end(ap);
    }
    bt_g.checks++;
    if (!ok) bt_g.fails++;
    bt_log("%s %s%s%s", ok ? "PASS" : "FAIL", what, details[0] ? ": " : "", details);
    return ok;
}

/* The numbers a person wants from the whole run, for the RESULT line ("59.9 fps on average, 2 stutters"). */
static inline void bt_headline(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(bt_g.headline, sizeof bt_g.headline, fmt, ap);
    va_end(ap);
}

/* The one result line; 1 when no check failed. "failed" is in it on purpose (see the top of this file). */
static inline int bt_result(void)
{
    int ok = bt_g.fails == 0 && bt_g.checks > 0;
    if (bt_g.checks == 0)
        snprintf(bt_g.head, sizeof bt_g.head, "FAIL (nothing ran)");
    else
        snprintf(bt_g.head, sizeof bt_g.head, "%s %d/%d", ok ? "PASS" : "FAIL", bt_g.checks - bt_g.fails, bt_g.checks);
    bt_log("RESULT %s (%d of %d checks passed, %d failed)%s%s", ok ? "PASS" : "FAIL", bt_g.checks - bt_g.fails, bt_g.checks, bt_g.fails, bt_g.headline[0] ? ": " : "", bt_g.headline);
    return ok;
}

static LONG WINAPI bt_crash_filter(EXCEPTION_POINTERS *ep)
{
    char where[200] = "";
    HMODULE m = NULL;
    const void *addr = ep->ExceptionRecord->ExceptionAddress;

    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)addr, &m) && m) {
        char path[MAX_PATH];
        if (GetModuleFileNameA(m, path, sizeof path)) {
            const char *base = strrchr(path, '\\');
            snprintf(where, sizeof where, " in %s+0x%lx", base ? base + 1 : path, (unsigned long)((const char *)addr - (const char *)m));
        }
    }
    bt_log("CRASH exception %#lx at %p%s; the test stops here", (unsigned long)ep->ExceptionRecord->ExceptionCode, addr, where);
    bt_g.fails++;
    bt_g.checks++;
    bt_log("RESULT FAIL (crash, 1 failed)");
    ExitProcess(70);
    return EXCEPTION_EXECUTE_HANDLER;
}

/* Names the program for the log, opens the .log mirror, and installs the crash filter. */
static inline void bt_init(const char *name)
{
    char path[MAX_PATH + 32];
    DWORD n;

    bt_g.name = name;
    bt_g.file = INVALID_HANDLE_VALUE;
    n = GetTempPathA(MAX_PATH, path);
    if (n > 0 && n < MAX_PATH) {
        strcat(path, "bcd-test.log");
        bt_g.file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    }
    SetUnhandledExceptionFilter(bt_crash_filter);
    bt_log("start");
}

/* ------------------------------------------------------------------ the text window */

#define BT_MAXLINES 600

enum { BT_INFO = 0, BT_PASS, BT_FAIL, BT_HEAD, BT_WARN };

typedef struct { char text[200]; int kind; } bt_line;

typedef struct bt_panel {
    HWND hwnd;
    HFONT font;
    int cw, ch;                       /* a character cell */
    int w, h;                         /* client size */
    bt_line *lines;
    int count, top;                   /* lines, first visible line */
    int follow;                       /* 1: keep the last line in view */
    int dirty, closed;
    int hook_h;                       /* height of the picture a program draws above the text, 0 for none */
    void (*paint_hook)(struct bt_panel *, HDC, int w, int h);          /* draws into [0, hook_h) */
    int (*msg_hook)(struct bt_panel *, UINT, WPARAM, LPARAM, LRESULT *); /* nonzero: handled */
    void *user;
    struct { RECT r; char label[40]; int id; } btn[8];
    int nbtn;
    int click;                        /* the id of the last button pressed or key mapped to one; 0 none */
    int last_key;                     /* the last virtual key pressed (not Escape) */
    int drag_y, dragging;
    char status[160];
} bt_panel;

static inline void bt_panel_layout(bt_panel *p)
{
    RECT r;
    int i, x = 8;
    GetClientRect(p->hwnd, &r);
    p->w = r.right;
    p->h = r.bottom;
    for (i = 0; i < p->nbtn; i++) {
        int bw = (int)strlen(p->btn[i].label) * p->cw + 24;
        p->btn[i].r.left = x;
        p->btn[i].r.right = x + bw;
        p->btn[i].r.top = p->h - 42;
        p->btn[i].r.bottom = p->h - 6;
        x += bw + 8;
    }
}

static inline int bt_panel_rows(const bt_panel *p)
{
    int bottom = p->h - (p->nbtn ? 48 : 22);
    int rows = (bottom - p->hook_h - 4) / (p->ch ? p->ch : 14);
    return rows < 1 ? 1 : rows;
}

static inline void bt_panel_clamp(bt_panel *p)
{
    int rows = bt_panel_rows(p), maxtop = p->count - rows;
    if (maxtop < 0) maxtop = 0;
    if (p->follow) p->top = maxtop;
    if (p->top > maxtop) p->top = maxtop;
    if (p->top < 0) p->top = 0;
}

static inline COLORREF bt_kind_color(int kind)
{
    switch (kind) {
    case BT_PASS: return RGB(90, 220, 120);
    case BT_FAIL: return RGB(255, 105, 105);
    case BT_HEAD: return RGB(255, 222, 120);
    case BT_WARN: return RGB(240, 180, 70);
    }
    return RGB(204, 208, 218);
}

static inline void bt_panel_paint(bt_panel *p, HDC target)
{
    HDC dc = CreateCompatibleDC(target);
    HBITMAP bmp = CreateCompatibleBitmap(target, p->w > 0 ? p->w : 1, p->h > 0 ? p->h : 1);
    HGDIOBJ oldbmp = SelectObject(dc, bmp), oldfont = SelectObject(dc, p->font);
    RECT all = { 0, 0, p->w, p->h };
    HBRUSH bg = CreateSolidBrush(RGB(18, 20, 28));
    int i, rows = bt_panel_rows(p), y;

    FillRect(dc, &all, bg);
    DeleteObject(bg);
    SetBkMode(dc, TRANSPARENT);
    if (p->hook_h > 0 && p->paint_hook) p->paint_hook(p, dc, p->w, p->hook_h);
    y = p->hook_h + 2;
    for (i = 0; i < rows && p->top + i < p->count; i++) {
        const bt_line *l = &p->lines[p->top + i];
        RECT cell = { 6, y, p->w - 14, y + p->ch };
        SetTextColor(dc, bt_kind_color(l->kind));
        DrawTextA(dc, l->text, -1, &cell, DT_LEFT | DT_NOPREFIX | DT_SINGLELINE | DT_NOCLIP);
        y += p->ch;
    }
    if (p->count > rows) {   /* a scroll bar thumb on the right */
        int track = rows * p->ch, thumb = track * rows / p->count, at;
        RECT t;
        HBRUSH tb = CreateSolidBrush(RGB(70, 76, 96));
        if (thumb < 16) thumb = 16;
        at = p->hook_h + 2 + (track - thumb) * p->top / (p->count - rows);
        t.left = p->w - 8; t.right = p->w - 2; t.top = at; t.bottom = at + thumb;
        FillRect(dc, &t, tb);
        DeleteObject(tb);
    }
    for (i = 0; i < p->nbtn; i++) {
        HBRUSH bb = CreateSolidBrush(RGB(48, 86, 150));
        RECT r = p->btn[i].r;
        FillRect(dc, &r, bb);
        DeleteObject(bb);
        SetTextColor(dc, RGB(255, 255, 255));
        DrawTextA(dc, p->btn[i].label, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    }
    if (p->status[0] && !p->nbtn) {   /* the button strip owns the bottom when there is one */
        RECT s = { 6, p->h - 20, p->w - 6, p->h };
        SetTextColor(dc, RGB(140, 150, 175));
        DrawTextA(dc, p->status, -1, &s, DT_LEFT | DT_NOPREFIX | DT_SINGLELINE);
    }
    BitBlt(target, 0, 0, p->w, p->h, dc, 0, 0, SRCCOPY);
    SelectObject(dc, oldfont);
    SelectObject(dc, oldbmp);
    DeleteObject(bmp);
    DeleteDC(dc);
}

static LRESULT CALLBACK bt_panel_proc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    bt_panel *p = (bt_panel *)GetWindowLongPtrA(h, GWLP_USERDATA);
    LRESULT res = 0;
    int i;

    if (m == WM_NCCREATE) {
        p = (bt_panel *)((CREATESTRUCTA *)l)->lpCreateParams;
        SetWindowLongPtrA(h, GWLP_USERDATA, (LONG_PTR)p);
        p->hwnd = h;
    }
    if (p && p->msg_hook && p->msg_hook(p, m, w, l, &res)) return res;
    switch (m) {
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE:
        if (p) { bt_panel_layout(p); bt_panel_clamp(p); InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_PAINT:
        if (p) {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            bt_panel_paint(p, dc);
            EndPaint(h, &ps);
            p->dirty = 0;
            return 0;
        }
        break;
    case WM_MOUSEWHEEL:
        if (p) {
            p->follow = 0;
            p->top -= (short)HIWORD(w) / WHEEL_DELTA * 3;
            bt_panel_clamp(p);
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_LBUTTONDOWN:
        if (p) {
            p->drag_y = (short)HIWORD(l);
            p->dragging = 1;
            SetCapture(h);
        }
        return 0;
    case WM_MOUSEMOVE:
        if (p && p->dragging && (w & MK_LBUTTON)) {   /* a finger drag on the text scrolls it */
            int y = (short)HIWORD(l), rows = (y - p->drag_y) / (p->ch ? p->ch : 14);
            if (rows) {
                p->follow = 0;
                p->top -= rows;
                p->drag_y += rows * p->ch;
                bt_panel_clamp(p);
                InvalidateRect(h, NULL, FALSE);
            }
        }
        return 0;
    case WM_LBUTTONUP:
        if (p) {
            POINT pt;
            pt.x = (short)LOWORD(l);
            pt.y = (short)HIWORD(l);
            p->dragging = 0;
            ReleaseCapture();
            for (i = 0; i < p->nbtn; i++)
                if (PtInRect(&p->btn[i].r, pt)) p->click = p->btn[i].id;
        }
        return 0;
    case WM_KEYDOWN:
        if (p) {
            if (w == VK_ESCAPE) { PostMessageA(h, WM_CLOSE, 0, 0); return 0; }
            p->last_key = (int)w;
            if (w == VK_UP) { p->follow = 0; p->top--; }
            else if (w == VK_DOWN) { p->top++; }
            else if (w == VK_PRIOR) { p->follow = 0; p->top -= bt_panel_rows(p) - 1; }
            else if (w == VK_NEXT) { p->top += bt_panel_rows(p) - 1; }
            bt_panel_clamp(p);
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_CLOSE:
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        if (p) p->closed = 1;
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(h, m, w, l);
}

/* A window of about w x h (client). `title` gets " (N-bit)" and, later, the verdict. */
static inline bt_panel *bt_panel_new(const char *title, int w, int h)
{
    WNDCLASSA wc;
    bt_panel *p = (bt_panel *)calloc(1, sizeof *p);
    RECT r = { 0, 0, w, h };
    const DWORD style = WS_OVERLAPPEDWINDOW;
    char full[160];
    HDC dc;
    TEXTMETRICA tm;

    if (!p) return NULL;
    p->lines = (bt_line *)calloc(BT_MAXLINES, sizeof(bt_line));
    if (!p->lines) { free(p); return NULL; }
    p->follow = 1;
    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = bt_panel_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.lpszClassName = "BCDTestPanel";
    if (!RegisterClassA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) { free(p->lines); free(p); return NULL; }
    p->font = CreateFontA(-15, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, ANSI_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                          DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN, "Courier New");
    dc = GetDC(NULL);
    SelectObject(dc, p->font);
    memset(&tm, 0, sizeof tm);
    GetTextMetricsA(dc, &tm);
    ReleaseDC(NULL, dc);
    p->cw = tm.tmAveCharWidth > 0 ? tm.tmAveCharWidth : 8;
    p->ch = (tm.tmHeight + tm.tmExternalLeading) > 0 ? tm.tmHeight + tm.tmExternalLeading : 16;
    {   /* a small desktop (a phone's Wine desktop): the window must fit with its title bar, or its buttons are out of reach */
        int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
        if (sw > 0 && r.right > sw - 24) r.right = sw - 24 > 480 ? sw - 24 : 480;
        if (sh > 0 && r.bottom > sh - 80) r.bottom = sh - 80 > 320 ? sh - 80 : 320;
    }
    AdjustWindowRect(&r, style, FALSE);
    snprintf(full, sizeof full, "BCD %s (%d-bit)", title, BT_BITS);
    p->hwnd = CreateWindowExA(0, wc.lpszClassName, full, style, 8, 8, r.right - r.left, r.bottom - r.top, NULL, NULL,
                              wc.hInstance, p);
    if (!p->hwnd) { free(p->lines); free(p); return NULL; }
    bt_panel_layout(p);
    ShowWindow(p->hwnd, SW_SHOW);
    UpdateWindow(p->hwnd);
    return p;
}

static inline void bt_panel_title(bt_panel *p, const char *title, const char *head)
{
    char full[200];
    if (!p) return;
    snprintf(full, sizeof full, "BCD %s (%d-bit)%s%s", title, BT_BITS, head && head[0] ? " - " : "", head ? head : "");
    SetWindowTextA(p->hwnd, full);
}

static inline void bt_panel_clear(bt_panel *p)
{
    if (!p) return;
    p->count = 0;
    p->top = 0;
    p->follow = 1;
    InvalidateRect(p->hwnd, NULL, FALSE);
}

static inline void bt_panel_button(bt_panel *p, int id, const char *label)
{
    if (!p || p->nbtn >= 8) return;
    p->btn[p->nbtn].id = id;
    snprintf(p->btn[p->nbtn].label, sizeof p->btn[p->nbtn].label, "%s", label);
    p->nbtn++;
    bt_panel_layout(p);
    bt_panel_clamp(p);
}

static inline void bt_panel_vline(bt_panel *p, int kind, const char *fmt, va_list ap)
{
    bt_line *l;
    if (!p) return;
    if (p->count == BT_MAXLINES) {   /* the oldest line goes */
        memmove(p->lines, p->lines + 1, (BT_MAXLINES - 1) * sizeof(bt_line));
        p->count--;
    }
    l = &p->lines[p->count++];
    vsnprintf(l->text, sizeof l->text, fmt, ap);
    l->kind = kind;
    bt_panel_clamp(p);
    InvalidateRect(p->hwnd, NULL, FALSE);
    p->dirty = 1;
}

static inline void bt_panel_line(bt_panel *p, int kind, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    bt_panel_vline(p, kind, fmt, ap);
    va_end(ap);
}

/* Messages for the window; 0 once it has been closed. */
static inline int bt_pump(bt_panel *p)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) { if (p) p->closed = 1; return 0; }
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    if (p && p->dirty) UpdateWindow(p->hwnd);
    return !(p && p->closed);
}

/* Pumps messages for `ms` milliseconds; 0 when the window was closed meanwhile. */
static inline int bt_sleep(bt_panel *p, DWORD ms)
{
    double end = bt_now() + ms / 1000.0;
    do {
        if (!bt_pump(p)) return 0;
        Sleep(5);
    } while (bt_now() < end);
    return bt_pump(p);
}

/* Waits for a button or a key and returns its id (a key letter as its upper-case character); 0 when the window closes. */
static inline int bt_wait_click(bt_panel *p)
{
    if (!p) return 0;
    p->click = 0;
    p->last_key = 0;
    while (bt_pump(p)) {
        if (p->click) { int id = p->click; p->click = 0; return id; }
        if (p->last_key >= 'A' && p->last_key <= 'Z') { int k = p->last_key; p->last_key = 0; return k; }
        Sleep(10);
    }
    return 0;
}

/* The same line to the window and the log, counted as a check. */
static inline int bt_report(bt_panel *p, int ok, const char *what, const char *fmt, ...)
{
    char details[300];
    va_list ap;
    details[0] = 0;
    if (fmt) {
        va_start(ap, fmt);
        vsnprintf(details, sizeof details, fmt, ap);
        va_end(ap);
    }
    bt_check(ok, what, "%s", details);
    bt_panel_line(p, ok ? BT_PASS : BT_FAIL, "%s  %s%s%s", ok ? "PASS" : "FAIL", what, details[0] ? ": " : "", details);
    return ok;
}

/* A line that is not a check: window and log. */
static inline void bt_note(bt_panel *p, int kind, const char *fmt, ...)
{
    char text[300];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    bt_log("%s", text);
    bt_panel_line(p, kind, "%s", text);
}

/* ------------------------------------------------------------------ small helpers */

/* An HRESULT as text for a line: "0x80070057". The buffer rotates, so several can sit in one printf. */
static inline const char *bt_hr(HRESULT hr)
{
    static char ring[4][16];
    static int at;
    char *s = ring[at++ & 3];
    snprintf(s, 16, "0x%08lx", (unsigned long)hr);
    return s;
}

/* A wide string as ASCII ('?' for the rest). */
static inline void bt_ascii(char *dst, size_t cap, const WCHAR *src)
{
    size_t i = 0;
    if (!cap) return;
    for (; src && src[i] && i + 1 < cap; i++) dst[i] = src[i] < 0x80 ? (char)src[i] : '?';
    dst[i] = 0;
}

#endif /* BCD_TEST_H */
