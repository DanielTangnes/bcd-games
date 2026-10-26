// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's controller test (round 602): what a game sees of a game controller, through the two APIs games use. x86-64 Windows.
//
// XInput (the Xbox-style API): the picture at the top shows the first connected pad as the game reads it with XInputGetState,
// about sixty times a second: the d-pad, A B X Y, the shoulders, Back and Start, both stick clicks, the two sticks with their
// dead zones and the two triggers as bars, and the raw numbers under it. Rumble: the buttons below (or L, H, B on the
// keyboard) run the left (low-frequency) motor, the right (high-frequency) motor or both for 0.7 seconds with
// XInputSetState; T makes the triggers drive the motors (left trigger the left motor, right trigger the right one), which is
// how a game's rumble follows the action. XInputGetCapabilities says what kind of pad it is.
// DirectInput 8: the attached game controllers (name, type, axes, buttons, hats), the keyboards and mice it knows, and the
// live state of the first game controller, polled through c_dfDIJoystick2.
//
// Every button press, release and stick movement is a line in the session log ("[bcd-test] controller (64-bit): pad 0 A down")
// for the first 80 events, so that a log from a controller that does not work shows where it stopped. The result lines:
//   PASS XInput library, PASS/FAIL "an XInput pad is connected" (FAIL when none), the pad's capabilities, the DirectInput
//   enumeration, and, when the window closes, whether the pad responded (a button or stick moved).

#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#include "bcdtest.h"
#include <xinput.h>
#include <dinput.h>

typedef DWORD (WINAPI *getstate_fn)(DWORD, XINPUT_STATE *);
typedef DWORD (WINAPI *setstate_fn)(DWORD, XINPUT_VIBRATION *);
typedef DWORD (WINAPI *getcaps_fn)(DWORD, DWORD, XINPUT_CAPABILITIES *);

static getstate_fn xi_get;
static setstate_fn xi_set;
static getcaps_fn xi_caps;

static XINPUT_STATE g_state[4];
static int g_connected[4], g_pad = -1;     /* the pad the picture shows */
static int g_events;
static unsigned g_seen_buttons;            /* buttons seen pressed at least once */
static int g_seen_stick[4], g_seen_trigger[2];
static int g_rumble_left, g_rumble_right;
static int g_di_pads = -1;   /* DirectInput game controllers attached; -1 when DirectInput did not start */
static int g_trigger_rumble;
static DIJOYSTATE2 g_di;
static int g_di_valid;
static char g_di_name[100];

static const struct { unsigned mask; const char *name; } buttons[] = {
    { XINPUT_GAMEPAD_A, "A" }, { XINPUT_GAMEPAD_B, "B" }, { XINPUT_GAMEPAD_X, "X" }, { XINPUT_GAMEPAD_Y, "Y" },
    { XINPUT_GAMEPAD_LEFT_SHOULDER, "LB" }, { XINPUT_GAMEPAD_RIGHT_SHOULDER, "RB" }, { XINPUT_GAMEPAD_BACK, "Back" }, { XINPUT_GAMEPAD_START, "Start" },
    { XINPUT_GAMEPAD_LEFT_THUMB, "L3" }, { XINPUT_GAMEPAD_RIGHT_THUMB, "R3" }, { XINPUT_GAMEPAD_DPAD_UP, "Up" }, { XINPUT_GAMEPAD_DPAD_DOWN, "Down" },
    { XINPUT_GAMEPAD_DPAD_LEFT, "Left" }, { XINPUT_GAMEPAD_DPAD_RIGHT, "Right" },
};

/* ------------------------------------------------------------------ the picture */

static void circle(HDC dc, int cx, int cy, int r, COLORREF fill, COLORREF line)
{
    HBRUSH b = CreateSolidBrush(fill);
    HPEN p = CreatePen(PS_SOLID, 2, line);
    HGDIOBJ ob = SelectObject(dc, b), op = SelectObject(dc, p);
    Ellipse(dc, cx - r, cy - r, cx + r, cy + r);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(b);
    DeleteObject(p);
}

static void box(HDC dc, int x, int y, int w, int h, COLORREF fill, COLORREF line)
{
    HBRUSH b = CreateSolidBrush(fill);
    HPEN p = CreatePen(PS_SOLID, 1, line);
    HGDIOBJ ob = SelectObject(dc, b), op = SelectObject(dc, p);
    Rectangle(dc, x, y, x + w, y + h);
    SelectObject(dc, ob);
    SelectObject(dc, op);
    DeleteObject(b);
    DeleteObject(p);
}

static void label(HDC dc, int x, int y, COLORREF c, const char *s)
{
    SetTextColor(dc, c);
    TextOutA(dc, x, y, s, (int)strlen(s));
}

static void stick(HDC dc, int cx, int cy, int r, int x, int y, int deadzone, int pressed)
{
    const COLORREF dim = RGB(70, 76, 96);
    int dz = r * deadzone / 32768;
    int px = cx + x * r / 32768, py = cy - y * r / 32768;
    circle(dc, cx, cy, r, RGB(28, 31, 42), dim);
    circle(dc, cx, cy, dz, RGB(40, 44, 58), RGB(110, 100, 60));
    circle(dc, px, py, 8, pressed ? RGB(255, 200, 60) : (abs(x) > deadzone || abs(y) > deadzone) ? RGB(90, 220, 120) : RGB(140, 150, 175), RGB(230, 230, 240));
}

static void paint_hook(bt_panel *p, HDC dc, int w, int h)
{
    const XINPUT_GAMEPAD *g;
    char t[160];
    unsigned b;
    int i;
    const COLORREF on = RGB(90, 220, 120), off = RGB(44, 48, 64), line = RGB(110, 118, 140);

    (void)p; (void)w; (void)h;
    if (g_pad < 0) {
        label(dc, 14, 14, RGB(255, 170, 120), "XInput: no controller connected.");
        label(dc, 14, 36, RGB(204, 208, 218), "Connect a controller (or pair one in BCD's controller settings) and it appears here at once.");
        label(dc, 14, 58, RGB(204, 208, 218), "XInput pads 0 to 3 are polled every frame, so a pad connected later is found.");
        return;
    }
    g = &g_state[g_pad].Gamepad;
    b = g->wButtons;
    snprintf(t, sizeof t, "XInput pad %d (packet %lu)", g_pad, (unsigned long)g_state[g_pad].dwPacketNumber);
    label(dc, 14, 6, RGB(255, 222, 120), t);

    /* triggers */
    for (i = 0; i < 2; i++) {
        int v = i == 0 ? g->bLeftTrigger : g->bRightTrigger, x = i == 0 ? 20 : 290;
        box(dc, x, 30, 80, 14, off, line);
        box(dc, x, 30, v * 80 / 255, 14, v > XINPUT_GAMEPAD_TRIGGER_THRESHOLD ? on : RGB(120, 130, 160), line);
        snprintf(t, sizeof t, "%s %3d", i == 0 ? "LT" : "RT", v);
        label(dc, x + 88, 30, RGB(204, 208, 218), t);
    }
    /* shoulders */
    box(dc, 20, 52, 80, 12, (b & XINPUT_GAMEPAD_LEFT_SHOULDER) ? on : off, line);
    label(dc, 40, 50, RGB(255, 255, 255), "LB");
    box(dc, 290, 52, 80, 12, (b & XINPUT_GAMEPAD_RIGHT_SHOULDER) ? on : off, line);
    label(dc, 310, 50, RGB(255, 255, 255), "RB");
    /* left stick, d-pad, right stick, face buttons */
    stick(dc, 70, 130, 42, g->sThumbLX, g->sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, (b & XINPUT_GAMEPAD_LEFT_THUMB) != 0);
    label(dc, 52, 176, RGB(204, 208, 218), "left stick");
    box(dc, 168, 198, 18, 18, (b & XINPUT_GAMEPAD_DPAD_UP) ? on : off, line);
    box(dc, 168, 238, 18, 18, (b & XINPUT_GAMEPAD_DPAD_DOWN) ? on : off, line);
    box(dc, 148, 218, 18, 18, (b & XINPUT_GAMEPAD_DPAD_LEFT) ? on : off, line);
    box(dc, 188, 218, 18, 18, (b & XINPUT_GAMEPAD_DPAD_RIGHT) ? on : off, line);
    label(dc, 150, 262, RGB(204, 208, 218), "d-pad");
    stick(dc, 215, 130, 42, g->sThumbRX, g->sThumbRY, XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE, (b & XINPUT_GAMEPAD_RIGHT_THUMB) != 0);
    label(dc, 192, 176, RGB(204, 208, 218), "right stick");
    box(dc, 118, 100, 28, 14, (b & XINPUT_GAMEPAD_BACK) ? on : off, line);
    label(dc, 120, 99, RGB(255, 255, 255), "Back");
    box(dc, 148, 100, 34, 14, (b & XINPUT_GAMEPAD_START) ? on : off, line);
    label(dc, 150, 99, RGB(255, 255, 255), "Start");
    {
        static const struct { int dx, dy; unsigned mask; const char *n; COLORREF c; } face[4] = {
            { 0, 30, XINPUT_GAMEPAD_A, "A", RGB(60, 190, 80) }, { 30, 0, XINPUT_GAMEPAD_B, "B", RGB(220, 70, 70) },
            { -30, 0, XINPUT_GAMEPAD_X, "X", RGB(70, 120, 230) }, { 0, -30, XINPUT_GAMEPAD_Y, "Y", RGB(230, 200, 60) } };
        for (i = 0; i < 4; i++) {
            circle(dc, 330 + face[i].dx, 150 + face[i].dy, 15, (b & face[i].mask) ? face[i].c : off, line);
            label(dc, 325 + face[i].dx, 142 + face[i].dy, RGB(255, 255, 255), face[i].n);
        }
    }
    /* the numbers and the rumble */
    snprintf(t, sizeof t, "LX %6d  LY %6d   RX %6d  RY %6d   buttons %04x", g->sThumbLX, g->sThumbLY, g->sThumbRX, g->sThumbRY, b);
    label(dc, 14, 280, RGB(204, 208, 218), t);
    snprintf(t, sizeof t, "rumble: left motor %d%%, right motor %d%%   triggers drive rumble: %s (T)", g_rumble_left * 100 / 65535, g_rumble_right * 100 / 65535, g_trigger_rumble ? "ON" : "off");
    label(dc, 14, 298, g_rumble_left || g_rumble_right ? RGB(255, 200, 60) : RGB(204, 208, 218), t);
    if (g_di_valid) {
        snprintf(t, sizeof t, "DirectInput \"%.40s\": X %ld Y %ld Z %ld Rx %ld Ry %ld Rz %ld POV %lu", g_di_name, (long)g_di.lX, (long)g_di.lY, (long)g_di.lZ, (long)g_di.lRx, (long)g_di.lRy,
                 (long)g_di.lRz, (unsigned long)g_di.rgdwPOV[0]);
        label(dc, 400, 6, RGB(160, 200, 255), t);
    }
}

/* ------------------------------------------------------------------ DirectInput */

typedef struct { bt_panel *pn; int count; GUID first; int have_first; char first_name[100]; } di_enum;

static const char *di_type(DWORD type)
{
    switch (GET_DIDEVICE_TYPE(type)) {
    case DI8DEVTYPE_GAMEPAD: return "gamepad";
    case DI8DEVTYPE_JOYSTICK: return "joystick";
    case DI8DEVTYPE_DRIVING: return "driving";
    case DI8DEVTYPE_FLIGHT: return "flight";
    case DI8DEVTYPE_1STPERSON: return "first person";
    case DI8DEVTYPE_SUPPLEMENTAL: return "supplemental";
    case DI8DEVTYPE_KEYBOARD: return "keyboard";
    case DI8DEVTYPE_MOUSE: return "mouse";
    case DI8DEVTYPE_DEVICE: return "device";
    }
    return "other";
}

static BOOL CALLBACK di_pad_cb(const DIDEVICEINSTANCEA *inst, void *ctx)
{
    di_enum *e = (di_enum *)ctx;
    bt_note(e->pn, BT_INFO, "  game controller %d: \"%.50s\" (%s), product %08lx", e->count, inst->tszInstanceName, di_type(inst->dwDevType), (unsigned long)inst->guidProduct.Data1);
    if (!e->have_first) {
        e->first = inst->guidInstance;
        e->have_first = 1;
        snprintf(e->first_name, sizeof e->first_name, "%s", inst->tszInstanceName);
    }
    e->count++;
    return DIENUM_CONTINUE;
}

static BOOL CALLBACK di_count_cb(const DIDEVICEINSTANCEA *inst, void *ctx)
{
    (void)inst;
    (*(int *)ctx)++;
    return DIENUM_CONTINUE;
}

static IDirectInputDevice8A *g_di_dev;

static void test_directinput(bt_panel *pn, HINSTANCE inst)
{
    IDirectInput8A *di = NULL;
    HRESULT hr = DirectInput8Create(inst, DIRECTINPUT_VERSION, &IID_IDirectInput8A, (void **)&di, NULL);
    di_enum e;
    int kbd = 0, mice = 0;

    bt_note(pn, BT_HEAD, "== DirectInput 8 ==");
    if (!bt_report(pn, SUCCEEDED(hr) && di, "DirectInput8Create", "%s", bt_hr(hr))) return;
    memset(&e, 0, sizeof e);
    e.pn = pn;
    hr = IDirectInput8_EnumDevices(di, DI8DEVCLASS_GAMECTRL, di_pad_cb, &e, DIEDFL_ATTACHEDONLY);
    bt_report(pn, SUCCEEDED(hr), "EnumDevices(game controllers)", "%s, %d attached", bt_hr(hr), e.count);
    g_di_pads = e.count;
    IDirectInput8_EnumDevices(di, DI8DEVCLASS_KEYBOARD, di_count_cb, &kbd, DIEDFL_ATTACHEDONLY);
    IDirectInput8_EnumDevices(di, DI8DEVCLASS_POINTER, di_count_cb, &mice, DIEDFL_ATTACHEDONLY);
    bt_note(pn, BT_INFO, "  keyboards %d, mice and pointers %d", kbd, mice);
    if (e.have_first) {
        hr = IDirectInput8_CreateDevice(di, &e.first, &g_di_dev, NULL);
        if (SUCCEEDED(hr) && g_di_dev) {
            DIDEVCAPS caps;
            memset(&caps, 0, sizeof caps);
            caps.dwSize = sizeof caps;
            IDirectInputDevice8_GetCapabilities(g_di_dev, &caps);
            bt_report(pn, caps.dwButtons > 0 || caps.dwAxes > 0, "the first controller's capabilities", "\"%.40s\": %lu axes, %lu buttons, %lu hat(s), flags %08lx", e.first_name,
                      (unsigned long)caps.dwAxes, (unsigned long)caps.dwButtons, (unsigned long)caps.dwPOVs, (unsigned long)caps.dwFlags);
            hr = IDirectInputDevice8_SetDataFormat(g_di_dev, &c_dfDIJoystick2);
            if (SUCCEEDED(hr)) hr = IDirectInputDevice8_SetCooperativeLevel(g_di_dev, pn->hwnd, DISCL_BACKGROUND | DISCL_NONEXCLUSIVE);
            if (SUCCEEDED(hr)) hr = IDirectInputDevice8_Acquire(g_di_dev);
            bt_report(pn, SUCCEEDED(hr), "SetDataFormat(DIJOYSTATE2), SetCooperativeLevel, Acquire", "%s", bt_hr(hr));
            snprintf(g_di_name, sizeof g_di_name, "%s", e.first_name);
        } else {
            bt_report(pn, 0, "CreateDevice for the first controller", "%s", bt_hr(hr));
            g_di_dev = NULL;
        }
    } else {
        bt_note(pn, BT_WARN, "  no DirectInput game controller attached");
    }
    IDirectInput8_Release(di);
}

/* ------------------------------------------------------------------ main */

static void rumble(int pad, int left, int right)
{
    XINPUT_VIBRATION v;
    v.wLeftMotorSpeed = (WORD)left;
    v.wRightMotorSpeed = (WORD)right;
    if (xi_set && pad >= 0) xi_set((DWORD)pad, &v);
    g_rumble_left = left;
    g_rumble_right = right;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    static const char *const dlls[] = { "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll" };
    bt_panel *pn;
    HMODULE m = NULL;
    int i, id, pads = 0, responded = 0;
    double rumble_end = 0, last_paint = 0;
    XINPUT_CAPABILITIES caps;
    DWORD r;
    const char *used = NULL;

    (void)prev; (void)cmd; (void)show;
    bt_init("controller");
    pn = bt_panel_new("controller test", 760, 640);
    if (!pn) { bt_check(0, "window", "could not be created"); bt_result(); return 1; }
    pn->hook_h = 320;
    pn->paint_hook = paint_hook;
    bt_panel_button(pn, 'L', "L: left motor");
    bt_panel_button(pn, 'H', "H: right motor");
    bt_panel_button(pn, 'B', "B: both motors");
    bt_panel_button(pn, 'T', "T: triggers rumble");
    bt_panel_button(pn, 'Q', "Close");

    bt_note(pn, BT_HEAD, "== XInput ==");
    for (i = 0; i < 3 && !xi_get; i++) {
        m = LoadLibraryA(dlls[i]);
        if (m) {
            xi_get = (getstate_fn)GetProcAddress(m, "XInputGetState");
            xi_set = (setstate_fn)GetProcAddress(m, "XInputSetState");
            xi_caps = (getcaps_fn)GetProcAddress(m, "XInputGetCapabilities");
            if (xi_get) used = dlls[i];
        }
    }
    if (!bt_report(pn, xi_get && xi_set, "XInput library", "%s", used ? used : "none of xinput1_4, xinput1_3, xinput9_1_0 has XInputGetState")) {
        bt_result();
        bt_panel_title(pn, "controller test", bt_g.head);
        while (bt_wait_click(pn)) {}
        return 1;
    }
    for (i = 0; i < 4; i++) {
        memset(&g_state[i], 0, sizeof g_state[i]);
        r = xi_get((DWORD)i, &g_state[i]);
        g_connected[i] = r == ERROR_SUCCESS;
        if (g_connected[i]) pads++;
        if (g_connected[i] && g_pad < 0) g_pad = i;
    }
    bt_report(pn, pads > 0, "an XInput pad is connected", "%d of 4 slots; pad %d is shown%s", pads, g_pad, pads ? "" : " (nothing to test: connect a controller)");
    if (g_pad >= 0 && xi_caps) {
        memset(&caps, 0, sizeof caps);
        r = xi_caps((DWORD)g_pad, 0, &caps);
        bt_report(pn, r == ERROR_SUCCESS, "XInputGetCapabilities", "type %u (1 = gamepad), subtype %u (1 = gamepad), flags %04x, buttons %04x, motors %s", caps.Type, caps.SubType, caps.Flags,
                  caps.Gamepad.wButtons, (caps.Vibration.wLeftMotorSpeed || caps.Vibration.wRightMotorSpeed) ? "yes" : "not reported");
    }
    test_directinput(pn, inst);
    bt_headline("%s, %d XInput pad(s) connected%s, %d DirectInput game controller(s); nothing touched yet", used, pads, pads && xi_caps ? " (pad shown has rumble motors if the capabilities line says so)" : "", g_di_pads);
    bt_result();   /* what is known before anyone touches the pad */
    bt_panel_title(pn, "controller test", bt_g.head);
    bt_note(pn, BT_INFO, "Move the sticks, press the buttons: the picture follows. Close the window for the final result.");

    while (bt_pump(pn)) {
        double now = bt_now();
        int changed = 0, p;

        for (p = 0; p < 4; p++) {
            XINPUT_STATE s;
            memset(&s, 0, sizeof s);
            r = xi_get((DWORD)p, &s);
            if ((r == ERROR_SUCCESS) != g_connected[p]) {
                g_connected[p] = r == ERROR_SUCCESS;
                bt_log("pad %d %s", p, g_connected[p] ? "connected" : "disconnected");
                if (g_connected[p] && g_pad < 0) g_pad = p;
                if (!g_connected[p] && g_pad == p) {
                    g_pad = -1;
                    for (i = 0; i < 4; i++) if (g_connected[i]) { g_pad = i; break; }
                }
                changed = 1;
            }
            if (r == ERROR_SUCCESS && s.dwPacketNumber != g_state[p].dwPacketNumber) {
                unsigned now_b = s.Gamepad.wButtons, was_b = g_state[p].Gamepad.wButtons, diff = now_b ^ was_b;
                size_t k;
                for (k = 0; k < sizeof buttons / sizeof buttons[0]; k++)
                    if (diff & buttons[k].mask) {
                        if (g_events++ < 80) bt_log("pad %d %s %s", p, buttons[k].name, (now_b & buttons[k].mask) ? "down" : "up");
                        if (now_b & buttons[k].mask) g_seen_buttons |= buttons[k].mask;
                    }
                if (abs(s.Gamepad.sThumbLX) > 16000 || abs(s.Gamepad.sThumbLY) > 16000) { if (!g_seen_stick[0] && g_events++ < 80) bt_log("pad %d left stick moved (%d, %d)", p, s.Gamepad.sThumbLX, s.Gamepad.sThumbLY); g_seen_stick[0] = 1; }
                if (abs(s.Gamepad.sThumbRX) > 16000 || abs(s.Gamepad.sThumbRY) > 16000) { if (!g_seen_stick[1] && g_events++ < 80) bt_log("pad %d right stick moved (%d, %d)", p, s.Gamepad.sThumbRX, s.Gamepad.sThumbRY); g_seen_stick[1] = 1; }
                if (s.Gamepad.bLeftTrigger > 128) { if (!g_seen_trigger[0] && g_events++ < 80) bt_log("pad %d left trigger %d", p, s.Gamepad.bLeftTrigger); g_seen_trigger[0] = 1; }
                if (s.Gamepad.bRightTrigger > 128) { if (!g_seen_trigger[1] && g_events++ < 80) bt_log("pad %d right trigger %d", p, s.Gamepad.bRightTrigger); g_seen_trigger[1] = 1; }
                g_state[p] = s;
                changed = 1;
            }
        }
        if (g_di_dev) {
            HRESULT hr = IDirectInputDevice8_Poll(g_di_dev);
            if (hr == DIERR_INPUTLOST || hr == DIERR_NOTACQUIRED) IDirectInputDevice8_Acquire(g_di_dev);
            if (SUCCEEDED(IDirectInputDevice8_GetDeviceState(g_di_dev, sizeof g_di, &g_di))) {
                if (!g_di_valid) bt_log("DirectInput state is readable: X %ld Y %ld", (long)g_di.lX, (long)g_di.lY);
                g_di_valid = 1;
                changed = 1;
            }
        }
        if (g_pad >= 0 && (g_seen_buttons || g_seen_stick[0] || g_seen_stick[1] || g_seen_trigger[0] || g_seen_trigger[1])) responded = 1;
        if (g_trigger_rumble && g_pad >= 0 && rumble_end == 0) {
            int l = g_state[g_pad].Gamepad.bLeftTrigger * 257, rr = g_state[g_pad].Gamepad.bRightTrigger * 257;
            if (l != g_rumble_left || rr != g_rumble_right) { rumble(g_pad, l, rr); changed = 1; }
        }
        if (rumble_end > 0 && now >= rumble_end) { rumble(g_pad, 0, 0); rumble_end = 0; changed = 1; }

        id = pn->click;
        if (!id && pn->last_key >= 'A' && pn->last_key <= 'Z') id = pn->last_key;
        pn->click = 0;
        pn->last_key = 0;
        if (id == 'Q') PostMessageA(pn->hwnd, WM_CLOSE, 0, 0);
        else if (id == 'T') { g_trigger_rumble = !g_trigger_rumble; if (!g_trigger_rumble && rumble_end == 0) rumble(g_pad, 0, 0); bt_log("triggers drive rumble: %s", g_trigger_rumble ? "on" : "off"); changed = 1; }
        else if ((id == 'L' || id == 'H' || id == 'B') && g_pad >= 0) {
            rumble(g_pad, id == 'H' ? 0 : 65535, id == 'L' ? 0 : 65535);
            rumble_end = now + 0.7;
            bt_log("rumble %s motor(s) for 0.7 s on pad %d", id == 'L' ? "left" : id == 'H' ? "right" : "both", g_pad);
            changed = 1;
        } else if ((id == 'L' || id == 'H' || id == 'B')) {
            bt_log("rumble requested with no pad connected");
        }
        if (changed || now - last_paint > 0.5) {
            InvalidateRect(pn->hwnd, NULL, FALSE);
            last_paint = now;
        }
        Sleep(8);
    }
    if (g_pad >= 0) rumble(g_pad, 0, 0);
    if (g_di_dev) { IDirectInputDevice8_Unacquire(g_di_dev); IDirectInputDevice8_Release(g_di_dev); }
    {
        char seen[200] = "";
        size_t k;
        for (k = 0; k < sizeof buttons / sizeof buttons[0]; k++)
            if ((g_seen_buttons & buttons[k].mask) && strlen(seen) + strlen(buttons[k].name) + 2 < sizeof seen) { strcat(seen, buttons[k].name); strcat(seen, " "); }
        if (pads > 0)
            bt_check(responded, "the pad responded", "buttons seen: %s; sticks moved: left %s, right %s; triggers: left %s, right %s", seen[0] ? seen : "none",
                     g_seen_stick[0] ? "yes" : "no", g_seen_stick[1] ? "yes" : "no", g_seen_trigger[0] ? "yes" : "no", g_seen_trigger[1] ? "yes" : "no");
    }
    bt_headline("%s, %d XInput pad(s) connected, %d DirectInput game controller(s); buttons seen %s, sticks moved %s/%s, triggers %s/%s", used, pads, g_di_pads,
                g_seen_buttons ? "yes" : "no", g_seen_stick[0] ? "L" : "-", g_seen_stick[1] ? "R" : "-", g_seen_trigger[0] ? "LT" : "-", g_seen_trigger[1] ? "RT" : "-");
    bt_result();
    return 0;
}
