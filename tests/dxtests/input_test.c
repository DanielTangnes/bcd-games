// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's keyboard, mouse and touch test (round 602): what a game receives from the keyboard and the pointer. x86-64 Windows.
//
// First it tests itself with synthetic input (SendInput into its own window), so that there are PASS and FAIL lines without
// anybody touching anything: SetCursorPos and GetCursorPos agree; an absolute mouse move arrives as WM_MOUSEMOVE at the
// right client position; a left click arrives as WM_LBUTTONDOWN and WM_LBUTTONUP; a wheel step arrives as WM_MOUSEWHEEL
// with a delta of 120; a key press arrives as WM_KEYDOWN, WM_CHAR and WM_KEYUP with the right virtual key and character;
// and raw input (RegisterRawInputDevices for the mouse and the keyboard, as most shooters use it) delivers WM_INPUT for them.
// Then it shows the real thing live: the top left of the window lists the keys held down, with the virtual-key code, scan code
// and extended flag of the last one (WM_KEYDOWN / WM_KEYUP / WM_CHAR, modifiers); the top right is a pad that shows the
// pointer, its trail, the five mouse buttons, both wheels and the raw input deltas; the lines below log every key, button
// and touch. Touch: RegisterTouchWindow, the screen's touch capabilities (GetSystemMetrics), WM_TOUCH and WM_POINTER*
// messages when they come, and whether a mouse click was made from a touch (GetMessageExtraInfo), which is how iOS touches
// reach a Windows game when nothing better exists. Mouse look: the M key (or its button) turns on the way many games read the
// mouse, GetCursorPos then SetCursorPos back to the middle of the window every frame, and counts how often the cursor did
// not stay where it was put.
//
// Escape closes the window. The session log gets every check ("[bcd-test] input (64-bit): PASS|FAIL ..."), the first 100 events
// and a RESULT line at the end.

#define COBJMACROS
#include "bcdtest.h"

#ifndef WM_POINTERDOWN
#define WM_POINTERUPDATE 0x0245
#define WM_POINTERDOWN 0x0246
#define WM_POINTERUP 0x0247
#endif
#ifndef MOUSEEVENTF_FROMTOUCH
#define MOUSEEVENTF_FROMTOUCH 0xFF515700
#endif
#ifndef SM_MAXIMUMTOUCHES
#define SM_MAXIMUMTOUCHES 95
#endif

typedef struct {
    int mx, my, buttons;
    int wheel, hwheel;
    int moves, downs, ups, wheels, key_down, key_up, chars, sys_keys;
    int raw_mouse, raw_kbd, raw_dx, raw_dy, raw_buttons;
    int touch_msgs, touch_points, pointer_msgs, from_touch;
    int last_vk, last_scan, last_ext, last_char;
    unsigned char held[256];
    POINT trail[80];
    int trail_n, trail_at;
    int log_lines;
    double last_move_log;
    /* the self-test's own counters */
    int st_move_x, st_move_y, st_lbtn_down, st_lbtn_up, st_wheel_delta, st_keydown_vk, st_char, st_keyup_vk;
    int testing;
    int look, look_miss, look_n, look_dx, look_dy;
} in_state;

static in_state S;
static bt_panel *g_pn;
static int (WINAPI *p_register_touch)(HWND, ULONG);
static int g_self_fails = -1, g_self_checks;

static const char *key_name(int scan, int ext, char *buf, size_t cap)
{
    LONG lp = (scan << 16) | (ext << 24);
    if (GetKeyNameTextA(lp, buf, (int)cap) <= 0) snprintf(buf, cap, "scan %02x", scan);
    return buf;
}

static void evlog(const char *fmt, ...)
{
    char text[200];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    if (S.log_lines++ < 100) bt_log("%s", text);
    bt_panel_line(g_pn, BT_INFO, "%s", text);
}

static int from_touch_now(void) { return (GetMessageExtraInfo() & 0xFFFFFF00) == 0xFF515700; }

static void trail_add(int x, int y)
{
    S.trail[S.trail_at].x = x;
    S.trail[S.trail_at].y = y;
    S.trail_at = (S.trail_at + 1) % 80;
    if (S.trail_n < 80) S.trail_n++;
}

#define PAD_X 380
#define PAD_Y 8
#define PAD_W 360
#define PAD_H 190

static void paint_hook(bt_panel *p, HDC dc, int w, int h)
{
    int i;
    char t[200], name[64];
    HBRUSH b;
    RECT pad = { PAD_X, PAD_Y, PAD_X + PAD_W, PAD_Y + PAD_H };
    HPEN pen, dim;
    HGDIOBJ op;
    RECT cl;
    int vx, vy;
    static const char *const bn[5] = { "L", "R", "M", "X1", "X2" };

    (void)w; (void)h;
    GetClientRect(p->hwnd, &cl);
    /* the mouse pad: the window's client area scaled into the rectangle */
    b = CreateSolidBrush(RGB(26, 30, 42));
    FillRect(dc, &pad, b);
    DeleteObject(b);
    dim = CreatePen(PS_SOLID, 1, RGB(70, 76, 96));
    op = SelectObject(dc, dim);
    MoveToEx(dc, pad.left, pad.top, NULL); LineTo(dc, pad.right - 1, pad.top); LineTo(dc, pad.right - 1, pad.bottom - 1); LineTo(dc, pad.left, pad.bottom - 1); LineTo(dc, pad.left, pad.top);
    SelectObject(dc, op);
    DeleteObject(dim);
    pen = CreatePen(PS_SOLID, 2, RGB(90, 220, 120));
    op = SelectObject(dc, pen);
    for (i = 1; i < S.trail_n; i++) {
        POINT a = S.trail[(S.trail_at - S.trail_n + i - 1 + 160) % 80], c = S.trail[(S.trail_at - S.trail_n + i + 160) % 80];
        int ax = PAD_X + a.x * PAD_W / (cl.right ? cl.right : 1), ay = PAD_Y + a.y * PAD_H / (cl.bottom ? cl.bottom : 1);
        int cx = PAD_X + c.x * PAD_W / (cl.right ? cl.right : 1), cy = PAD_Y + c.y * PAD_H / (cl.bottom ? cl.bottom : 1);
        if (ax < PAD_X || cx < PAD_X || ax >= PAD_X + PAD_W || cx >= PAD_X + PAD_W || ay < PAD_Y || cy < PAD_Y || ay >= PAD_Y + PAD_H || cy >= PAD_Y + PAD_H) continue;
        MoveToEx(dc, ax, ay, NULL);
        LineTo(dc, cx, cy);
    }
    SelectObject(dc, op);
    DeleteObject(pen);
    vx = PAD_X + S.mx * PAD_W / (cl.right ? cl.right : 1);
    vy = PAD_Y + S.my * PAD_H / (cl.bottom ? cl.bottom : 1);
    if (vx >= PAD_X && vx < PAD_X + PAD_W && vy >= PAD_Y && vy < PAD_Y + PAD_H) {
        pen = CreatePen(PS_SOLID, 1, S.buttons ? RGB(255, 200, 60) : RGB(230, 230, 240));
        op = SelectObject(dc, pen);
        MoveToEx(dc, vx - 8, vy, NULL); LineTo(dc, vx + 9, vy);
        MoveToEx(dc, vx, vy - 8, NULL); LineTo(dc, vx, vy + 9);
        SelectObject(dc, op);
        DeleteObject(pen);
    }
    SetBkMode(dc, TRANSPARENT);
    /* the five buttons */
    for (i = 0; i < 5; i++) {
        RECT r = { PAD_X + i * 40, PAD_Y + PAD_H + 6, PAD_X + i * 40 + 36, PAD_Y + PAD_H + 28 };
        b = CreateSolidBrush((S.buttons & (1 << i)) ? RGB(90, 220, 120) : RGB(44, 48, 64));
        FillRect(dc, &r, b);
        DeleteObject(b);
        SetTextColor(dc, RGB(255, 255, 255));
        DrawTextA(dc, bn[i], -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    snprintf(t, sizeof t, "pointer %d,%d  wheel %d  hwheel %d  moves %d%s", S.mx, S.my, S.wheel, S.hwheel, S.moves, S.from_touch ? "  (from touch)" : "");
    SetTextColor(dc, RGB(204, 208, 218));
    TextOutA(dc, PAD_X, PAD_Y + PAD_H + 32, t, (int)strlen(t));
    snprintf(t, sizeof t, "raw input: mouse %d events (sum dx %d dy %d, buttons %d), keyboard %d", S.raw_mouse, S.raw_dx, S.raw_dy, S.raw_buttons, S.raw_kbd);
    TextOutA(dc, PAD_X, PAD_Y + PAD_H + 50, t, (int)strlen(t));
    snprintf(t, sizeof t, "touch: WM_TOUCH %d (%d points), WM_POINTER %d", S.touch_msgs, S.touch_points, S.pointer_msgs);
    TextOutA(dc, PAD_X, PAD_Y + PAD_H + 68, t, (int)strlen(t));
    if (S.look) {
        snprintf(t, sizeof t, "mouse look ON: moved %d,%d in %d frames; cursor stayed put %d/%d", S.look_dx, S.look_dy, S.look_n, S.look_n - S.look_miss, S.look_n);
        SetTextColor(dc, RGB(255, 200, 60));
        TextOutA(dc, PAD_X, PAD_Y + PAD_H + 86, t, (int)strlen(t));
    }

    /* the keyboard */
    SetTextColor(dc, RGB(255, 222, 120));
    TextOutA(dc, 10, 8, "Keyboard", 8);
    SetTextColor(dc, RGB(204, 208, 218));
    {
        char held[300] = "";
        int n = 0;
        for (i = 1; i < 256; i++)
            if (S.held[i] && n < 14) {
                char one[16];
                snprintf(one, sizeof one, "%s%02X", n ? " " : "", i);
                strcat(held, one);
                n++;
            }
        snprintf(t, sizeof t, "held (virtual-key codes): %s", n ? held : "none");
        TextOutA(dc, 10, 30, t, (int)strlen(t));
    }
    snprintf(t, sizeof t, "last: VK %02X  scan %02X  %s  %s", S.last_vk, S.last_scan, S.last_ext ? "extended" : "normal", key_name(S.last_scan, S.last_ext, name, sizeof name));
    TextOutA(dc, 10, 50, t, (int)strlen(t));
    snprintf(t, sizeof t, "last character: %c (%d)", S.last_char >= 32 && S.last_char < 127 ? S.last_char : '-', S.last_char);
    TextOutA(dc, 10, 70, t, (int)strlen(t));
    snprintf(t, sizeof t, "Shift %s  Ctrl %s  Alt %s  CapsLock %s", (GetKeyState(VK_SHIFT) & 0x8000) ? "ON" : "-", (GetKeyState(VK_CONTROL) & 0x8000) ? "ON" : "-",
             (GetKeyState(VK_MENU) & 0x8000) ? "ON" : "-", (GetKeyState(VK_CAPITAL) & 1) ? "ON" : "-");
    TextOutA(dc, 10, 90, t, (int)strlen(t));
    snprintf(t, sizeof t, "WM_KEYDOWN %d  WM_KEYUP %d  WM_SYSKEY* %d  WM_CHAR %d", S.key_down, S.key_up, S.sys_keys, S.chars);
    TextOutA(dc, 10, 110, t, (int)strlen(t));
    SetTextColor(dc, RGB(140, 150, 175));
    TextOutA(dc, 10, 140, "Type, click, scroll, tap. M: mouse look. Esc closes.", 52);
}

/* Mouse look on or off: the cursor hidden and put in the middle of the window each frame while on. */
static void toggle_look(bt_panel *p)
{
    S.look = !S.look;
    S.look_miss = S.look_n = S.look_dx = S.look_dy = 0;
    ShowCursor(S.look ? FALSE : TRUE);
    if (S.look) {
        RECT cr;
        POINT c;
        GetClientRect(p->hwnd, &cr);
        c.x = cr.right / 2; c.y = cr.bottom / 2;
        ClientToScreen(p->hwnd, &c);
        SetCursorPos(c.x, c.y);
    }
    bt_log("mouse look %s", S.look ? "on" : "off");
}

/* the window's messages, ahead of the panel's own */
static int msg_hook(bt_panel *p, UINT m, WPARAM w, LPARAM l, LRESULT *res)
{
    char nm[64];
    (void)res;
    switch (m) {
    case WM_MOUSEMOVE: {
        int x = (short)LOWORD(l), y = (short)HIWORD(l);
        S.moves++;
        S.mx = x; S.my = y;
        S.from_touch = from_touch_now();
        S.st_move_x = x; S.st_move_y = y;
        trail_add(x, y);
        if (!S.testing && bt_now() - S.last_move_log > 0.4) { S.last_move_log = bt_now(); evlog("WM_MOUSEMOVE %d,%d%s", x, y, S.from_touch ? " (from touch)" : ""); }
        InvalidateRect(p->hwnd, NULL, FALSE);
        return 0;   /* the panel's drag-to-scroll still sees it */
    }
    case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN: case WM_XBUTTONDOWN: {
        int bit = m == WM_LBUTTONDOWN ? 0 : m == WM_RBUTTONDOWN ? 1 : m == WM_MBUTTONDOWN ? 2 : (HIWORD(w) == XBUTTON1 ? 3 : 4);
        S.downs++;
        S.buttons |= 1 << bit;
        S.from_touch = from_touch_now();
        if (bit == 0) S.st_lbtn_down++;
        evlog("button %s down at %d,%d%s", bit == 0 ? "left" : bit == 1 ? "right" : bit == 2 ? "middle" : bit == 3 ? "X1" : "X2", (short)LOWORD(l), (short)HIWORD(l),
              S.from_touch ? " (from touch)" : "");
        InvalidateRect(p->hwnd, NULL, FALSE);
        return 0;
    }
    case WM_LBUTTONUP: case WM_RBUTTONUP: case WM_MBUTTONUP: case WM_XBUTTONUP: {
        int bit = m == WM_LBUTTONUP ? 0 : m == WM_RBUTTONUP ? 1 : m == WM_MBUTTONUP ? 2 : (HIWORD(w) == XBUTTON1 ? 3 : 4);
        S.ups++;
        S.buttons &= ~(1 << bit);
        if (bit == 0) S.st_lbtn_up++;
        evlog("button %s up at %d,%d", bit == 0 ? "left" : bit == 1 ? "right" : bit == 2 ? "middle" : bit == 3 ? "X1" : "X2", (short)LOWORD(l), (short)HIWORD(l));
        InvalidateRect(p->hwnd, NULL, FALSE);
        return 0;
    }
    case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL: {
        int d = (short)HIWORD(w);
        S.wheels++;
        if (m == WM_MOUSEWHEEL) { S.wheel += d; S.st_wheel_delta = d; } else S.hwheel += d;
        evlog("%s delta %d", m == WM_MOUSEWHEEL ? "WM_MOUSEWHEEL" : "WM_MOUSEHWHEEL", d);
        InvalidateRect(p->hwnd, NULL, FALSE);
        return 0;
    }
    case WM_KEYDOWN: case WM_SYSKEYDOWN: {
        int scan = (l >> 16) & 0xFF, ext = (l >> 24) & 1, rep = (int)(l & 0xFFFF);
        if (m == WM_SYSKEYDOWN) S.sys_keys++;
        S.key_down++;
        S.last_vk = (int)w; S.last_scan = scan; S.last_ext = ext;
        if (w < 256) S.held[w] = 1;
        S.st_keydown_vk = (int)w;
        if (rep <= 1) evlog("WM_KEYDOWN VK %02X (%s) scan %02X%s", (unsigned)w, key_name(scan, ext, nm, sizeof nm), scan, ext ? " extended" : "");
        InvalidateRect(p->hwnd, NULL, FALSE);
        if (w == VK_ESCAPE) return 0;       /* the panel closes the window */
        if (w == 'M' && !S.testing && m == WM_KEYDOWN && !(l & 0x40000000)) toggle_look(p);
        return m == WM_SYSKEYDOWN ? 0 : 1;   /* Alt+F4 and the system keys still reach Windows; the panel's scrolling keys do not */
    }
    case WM_KEYUP: case WM_SYSKEYUP: {
        int scan = (l >> 16) & 0xFF, ext = (l >> 24) & 1;
        S.key_up++;
        if (w < 256) S.held[w] = 0;
        S.st_keyup_vk = (int)w;
        evlog("WM_KEYUP VK %02X (%s)", (unsigned)w, key_name(scan, ext, nm, sizeof nm));
        InvalidateRect(p->hwnd, NULL, FALSE);
        return m == WM_SYSKEYUP ? 0 : 1;
    }
    case WM_CHAR:
        S.chars++;
        S.last_char = (int)w;
        S.st_char = (int)w;
        evlog("WM_CHAR %d '%c'", (int)w, w >= 32 && w < 127 ? (char)w : '?');
        InvalidateRect(p->hwnd, NULL, FALSE);
        return 1;
    case WM_INPUT: {
        UINT size = 0;
        BYTE buf[256];
        GetRawInputData((HRAWINPUT)l, RID_INPUT, NULL, &size, sizeof(RAWINPUTHEADER));
        if (size > 0 && size <= sizeof buf && GetRawInputData((HRAWINPUT)l, RID_INPUT, buf, &size, sizeof(RAWINPUTHEADER)) == size) {
            const RAWINPUT *ri = (const RAWINPUT *)buf;
            if (ri->header.dwType == RIM_TYPEMOUSE) {
                S.raw_mouse++;
                S.raw_dx += ri->data.mouse.lLastX;
                S.raw_dy += ri->data.mouse.lLastY;
                if (ri->data.mouse.usButtonFlags) S.raw_buttons++;
            } else if (ri->header.dwType == RIM_TYPEKEYBOARD) {
                S.raw_kbd++;
            }
        }
        return 0;
    }
    case WM_TOUCH: {
        UINT n = LOWORD(w);
        S.touch_msgs++;
        S.touch_points += (int)n;
        if (S.touch_msgs < 12) evlog("WM_TOUCH with %u point(s)", n);
        return 0;
    }
    case WM_POINTERDOWN: case WM_POINTERUP: case WM_POINTERUPDATE:
        S.pointer_msgs++;
        if (S.pointer_msgs < 12 && m != WM_POINTERUPDATE) evlog("WM_POINTER%s id %u", m == WM_POINTERDOWN ? "DOWN" : "UP", (unsigned)LOWORD(w));
        return 0;
    }
    return 0;
}

/* ------------------------------------------------------------------ the self-test */

static void pump_for(bt_panel *pn, DWORD ms) { bt_sleep(pn, ms); }

static void send_mouse(DWORD flags, int abs_x, int abs_y, DWORD data)
{
    INPUT in;
    memset(&in, 0, sizeof in);
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = flags;
    in.mi.dx = abs_x;
    in.mi.dy = abs_y;
    in.mi.mouseData = data;
    SendInput(1, &in, sizeof in);
}

static void send_key(WORD vk, DWORD flags)
{
    INPUT in;
    memset(&in, 0, sizeof in);
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.wScan = (WORD)MapVirtualKeyA(vk, MAPVK_VK_TO_VSC);
    in.ki.dwFlags = flags;
    SendInput(1, &in, sizeof in);
}

static void self_test(bt_panel *pn)
{
    RECT cr;
    POINT c, target, back;
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN), raw0, i;
    RAWINPUTDEVICE rid[2];
    BOOL reg;
    int n_mouse = 0, n_kbd = 0, n_hid = 0;
    UINT ndev = 0;

    bt_note(pn, BT_HEAD, "== self-test with synthetic input ==");
    S.testing = 1;
    SetForegroundWindow(pn->hwnd);
    SetFocus(pn->hwnd);
    pump_for(pn, 300);
    GetClientRect(pn->hwnd, &cr);

    /* the devices Windows knows */
    if (GetRawInputDeviceList(NULL, &ndev, sizeof(RAWINPUTDEVICELIST)) == 0 && ndev > 0) {
        RAWINPUTDEVICELIST *list = (RAWINPUTDEVICELIST *)calloc(ndev, sizeof *list);
        if (list && GetRawInputDeviceList(list, &ndev, sizeof(RAWINPUTDEVICELIST)) != (UINT)-1)
            for (i = 0; i < (int)ndev; i++) {
                if (list[i].dwType == RIM_TYPEMOUSE) n_mouse++;
                else if (list[i].dwType == RIM_TYPEKEYBOARD) n_kbd++;
                else n_hid++;
            }
        free(list);
    }
    bt_note(pn, BT_INFO, "  raw input devices: %d mouse, %d keyboard, %d other HID; screen %dx%d; mouse buttons %d, wheel %s, touch points %d (digitizer flags %02x)", n_mouse, n_kbd, n_hid, sw, sh,
            GetSystemMetrics(SM_CMOUSEBUTTONS), GetSystemMetrics(SM_MOUSEWHEELPRESENT) ? "yes" : "no", GetSystemMetrics(SM_MAXIMUMTOUCHES), (unsigned)GetSystemMetrics(94 /* SM_DIGITIZER */));

    /* raw input, the way shooters ask for it */
    memset(rid, 0, sizeof rid);
    rid[0].usUsagePage = 1; rid[0].usUsage = 2; rid[0].dwFlags = RIDEV_INPUTSINK; rid[0].hwndTarget = pn->hwnd;   /* mouse */
    rid[1].usUsagePage = 1; rid[1].usUsage = 6; rid[1].dwFlags = RIDEV_INPUTSINK; rid[1].hwndTarget = pn->hwnd;   /* keyboard */
    reg = RegisterRawInputDevices(rid, 2, sizeof(RAWINPUTDEVICE));
    bt_report(pn, reg, "RegisterRawInputDevices (mouse and keyboard)", "%s (error %lu)", reg ? "accepted" : "refused", reg ? 0UL : GetLastError());

    /* SetCursorPos / GetCursorPos */
    c.x = cr.right / 2; c.y = cr.bottom / 2;
    ClientToScreen(pn->hwnd, &c);
    SetCursorPos(c.x, c.y);
    GetCursorPos(&back);
    bt_report(pn, back.x == c.x && back.y == c.y, "SetCursorPos then GetCursorPos", "put the cursor at %ld,%ld, read %ld,%ld", (long)c.x, (long)c.y, (long)back.x, (long)back.y);
    pump_for(pn, 150);

    /* an absolute move to a point in the client area */
    target.x = 60; target.y = 50;
    c = target;
    ClientToScreen(pn->hwnd, &c);
    S.st_move_x = S.st_move_y = -1;
    raw0 = S.raw_mouse;
    send_mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, c.x * 65535 / (sw > 1 ? sw - 1 : 1), c.y * 65535 / (sh > 1 ? sh - 1 : 1), 0);
    pump_for(pn, 300);
    bt_report(pn, abs(S.st_move_x - target.x) <= 3 && abs(S.st_move_y - target.y) <= 3, "SendInput absolute move arrives as WM_MOUSEMOVE", "asked for client %ld,%ld, the window got %d,%d", (long)target.x, (long)target.y,
              S.st_move_x, S.st_move_y);

    /* a left click */
    S.st_lbtn_down = S.st_lbtn_up = 0;
    send_mouse(MOUSEEVENTF_LEFTDOWN, 0, 0, 0);
    pump_for(pn, 120);
    send_mouse(MOUSEEVENTF_LEFTUP, 0, 0, 0);
    pump_for(pn, 250);
    bt_report(pn, S.st_lbtn_down == 1 && S.st_lbtn_up == 1, "SendInput left click arrives as WM_LBUTTONDOWN + WM_LBUTTONUP", "%d down, %d up", S.st_lbtn_down, S.st_lbtn_up);

    /* a wheel step */
    S.st_wheel_delta = 0;
    send_mouse(MOUSEEVENTF_WHEEL, 0, 0, WHEEL_DELTA);
    pump_for(pn, 250);
    bt_report(pn, S.st_wheel_delta == WHEEL_DELTA, "SendInput wheel step arrives as WM_MOUSEWHEEL", "delta %d (expected %d)", S.st_wheel_delta, WHEEL_DELTA);

    /* raw input for those */
    bt_report(pn, !reg || S.raw_mouse > raw0, "WM_INPUT for the injected mouse input", "%d raw mouse event(s) arrived, sum dx %d dy %d, %d with buttons", S.raw_mouse - raw0, S.raw_dx, S.raw_dy, S.raw_buttons);

    /* a key: Z gives WM_KEYDOWN 'Z', WM_CHAR 'z', WM_KEYUP 'Z' */
    S.st_keydown_vk = S.st_keyup_vk = S.st_char = 0;
    raw0 = S.raw_kbd;
    send_key('Z', 0);
    pump_for(pn, 200);
    send_key('Z', KEYEVENTF_KEYUP);
    pump_for(pn, 250);
    bt_report(pn, S.st_keydown_vk == 'Z' && S.st_char == 'z' && S.st_keyup_vk == 'Z', "SendInput key arrives as WM_KEYDOWN + WM_CHAR + WM_KEYUP",
              "down VK %02X (expected 5A), character %d (expected 122), up VK %02X", S.st_keydown_vk, S.st_char, S.st_keyup_vk);
    bt_report(pn, !reg || S.raw_kbd > raw0, "WM_INPUT for the injected key", "%d raw keyboard event(s) arrived", S.raw_kbd - raw0);

    /* touch: what the window can be told */
    {
        BOOL t = p_register_touch ? p_register_touch(pn->hwnd, 0) : FALSE;
        bt_report(pn, 1, "touch support (information)", "RegisterTouchWindow %s; GetSystemMetrics: max touches %d, digitizer %02x; the first real touch will say whether it comes as WM_TOUCH or as a mouse click",
                  p_register_touch ? (t ? "accepted" : "refused") : "is not exported", GetSystemMetrics(SM_MAXIMUMTOUCHES), (unsigned)GetSystemMetrics(94));
    }
    S.testing = 0;
    g_self_checks = bt_g.checks;
    g_self_fails = bt_g.fails;
    S.log_lines = 0;
    memset(S.held, 0, sizeof S.held);
    S.moves = 0; S.downs = S.ups = S.wheels = 0; S.wheel = 0; S.key_down = S.key_up = S.chars = 0;
}

/* ------------------------------------------------------------------ main */

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    bt_panel *pn;
    int id;
    double last_paint = 0;

    (void)inst; (void)prev; (void)cmd; (void)show;
    bt_init("input");
    pn = bt_panel_new("keyboard, mouse and touch test", 780, 640);
    if (!pn) { bt_check(0, "window", "could not be created"); bt_result(); return 1; }
    g_pn = pn;
    pn->hook_h = 270;
    pn->paint_hook = paint_hook;
    pn->msg_hook = msg_hook;
    bt_panel_button(pn, 'M', "M: mouse look");
    bt_panel_button(pn, 'Q', "Close");
    p_register_touch = (int (WINAPI *)(HWND, ULONG))GetProcAddress(GetModuleHandleA("user32.dll"), "RegisterTouchWindow");

    self_test(pn);
    bt_headline("self-test with SendInput: %d of %d checks passed (move, click, wheel, key, raw input), touch points reported by the screen: %d", g_self_checks - g_self_fails, g_self_checks,
                GetSystemMetrics(SM_MAXIMUMTOUCHES));
    bt_result();
    bt_panel_title(pn, "keyboard, mouse and touch test", bt_g.head);
    bt_note(pn, bt_g.fails ? BT_FAIL : BT_PASS, "Self-test: %s (%d of %d checks). Now try the real keys, mouse and fingers; the lines below are the events.", bt_g.fails ? "FAIL" : "PASS", bt_g.checks - bt_g.fails, bt_g.checks);

    while (bt_pump(pn)) {
        double now = bt_now();
        if (S.look) {   /* mouse look: read the cursor, put it back in the middle, count the misses */
            RECT cr;
            POINT c, p;
            GetClientRect(pn->hwnd, &cr);
            c.x = cr.right / 2; c.y = cr.bottom / 2;
            ClientToScreen(pn->hwnd, &c);
            if (GetCursorPos(&p)) {
                S.look_dx += p.x - c.x;
                S.look_dy += p.y - c.y;
                SetCursorPos(c.x, c.y);
                {
                    POINT q;
                    GetCursorPos(&q);
                    if (q.x != c.x || q.y != c.y) S.look_miss++;
                }
                S.look_n++;
            }
        }
        id = pn->click;
        pn->click = 0;
        if (id == 'Q') PostMessageA(pn->hwnd, WM_CLOSE, 0, 0);
        if (id == 'M') toggle_look(pn);
        if (now - last_paint > 0.1) { InvalidateRect(pn->hwnd, NULL, FALSE); last_paint = now; }
        Sleep(8);
    }
    if (S.look) ShowCursor(TRUE);
    bt_log("live input seen: mouse moves %d, button downs %d, ups %d, wheel events %d, key downs %d, key ups %d, characters %d, raw mouse %d, raw keyboard %d, WM_TOUCH %d, WM_POINTER %d, "
           "mouse events from touch: %s", S.moves, S.downs, S.ups, S.wheels, S.key_down, S.key_up, S.chars, S.raw_mouse, S.raw_kbd, S.touch_msgs, S.pointer_msgs, S.from_touch ? "yes" : "no");
    bt_headline("self-test %d of %d checks passed; live: %d moves, %d clicks, %d key downs, %d raw mouse, WM_TOUCH %d, WM_POINTER %d, touch-made clicks %s", g_self_checks - g_self_fails,
                g_self_checks, S.moves, S.downs, S.key_down, S.raw_mouse, S.touch_msgs, S.pointer_msgs, S.from_touch ? "yes" : "no");
    bt_result();
    return 0;
}
