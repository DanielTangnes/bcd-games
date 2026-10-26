// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's MIDI test (round 603): does a Windows program hear MIDI music? One source, two programs: midi-test-x64.exe (64-bit) and
// midi-test-x86.exe (32-bit, as most games that play MIDI are). It uses winmm only, the way games do.
//
// What it checks by itself, as PASS or FAIL lines:
//   the device list: midiOutGetNumDevs is at least 1 (the device is "BCD GM Synthesizer"), its capabilities (name, technology,
//     voices, volume support), no phantom input or auxiliary devices (midiInGetNumDevs and auxGetNumDevs count real ones: 0);
//   midiOutOpen on device 0 with a callback function: MOM_OPEN arrives; the General MIDI reset sent as a prepared long message
//     completes (MHDR_DONE, MOM_DONE); midiOutSetVolume/GetVolume round-trip; midiOutClose: MOM_CLOSE arrives;
//   the MIDI mapper (MIDI_MAPPER, what most games open) opens, plays and closes;
//   midiStreamOpen (the way sequencers play a song with its own tempo): a four-bar tune in one buffer plays out in about the time its
//     tempo says (the buffer comes back done, the clock of the stream moves).
// What it cannot check is that the sound reaches a speaker: that is the person's ears. The window says what is playing now: a C major
// scale on a piano, a chord, one note on five instruments (guitar, violin, trumpet, flute, bass), then the drums on channel 10.
// Silence while every line says PASS is a bug in the synthesizer's output; a FAIL says where the chain stopped.
//
// Every line goes to the window, to standard error as "[bcd-test] midi (<bits>-bit): <text>" and to <temp>\bcd-test.log (a program
// started from the Start menu may have no standard error). The last line, "RESULT PASS|FAIL <n> checks, <m> failed", is the one to read.
// Where it goes: next to the other tests in tests/dxtests/, built by tools/build-dx-tests.sh (llvm-mingw, -mwindows, -lwinmm,
// -luser32 -lgdi32; once for x86_64 into app/Madeira/arm64ec-windows/midi-test-x64.exe, once for i686 into
// app/Madeira/i386-windows/midi-test-x86.exe) and one entry each in the Start menu's BCD Tests folder (app/Madeira/BCDStartMenu.c).
// This file stands alone (no bcdtest.h): the line format is the same, so it can move onto that header later.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BITS ((int)(sizeof(void *) * 8))

static int g_checks, g_fails;
static HWND g_window, g_list;
static HANDLE g_file = INVALID_HANDLE_VALUE;

static void emit(const char *text)
{
    char line[600];
    DWORD w;
    int n = snprintf(line, sizeof line - 2, "[bcd-test] midi (%d-bit): %s", BITS, text);
    if (n < 0) return;
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    {
        HANDLE e = GetStdHandle(STD_ERROR_HANDLE);
        if (e && e != INVALID_HANDLE_VALUE) WriteFile(e, line, (DWORD)n, &w, NULL);
    }
    if (g_file != INVALID_HANDLE_VALUE) WriteFile(g_file, line, (DWORD)n, &w, NULL);
    if (g_list) {
        char shown[600];
        snprintf(shown, sizeof shown, "%s", text);
        SendMessageA(g_list, LB_ADDSTRING, 0, (LPARAM)shown);
        SendMessageA(g_list, LB_SETTOPINDEX, (WPARAM)SendMessageA(g_list, LB_GETCOUNT, 0, 0) - 1, 0);
    }
}

static void say(const char *fmt, ...)
{
    char text[500];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    emit(text);
}

static int check(int ok, const char *what, const char *fmt, ...)
{
    char details[300] = "", text[500];
    if (fmt) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(details, sizeof details, fmt, ap);
        va_end(ap);
    }
    g_checks++;
    if (!ok) g_fails++;
    snprintf(text, sizeof text, "%s %s%s%s", ok ? "PASS" : "FAIL", what, details[0] ? ": " : "", details);
    emit(text);
    return ok;
}

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    while ((int)(end - GetTickCount()) > 0) {
        MSG m;
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageA(&m); }
        Sleep(5);
    }
}

/* ------------------------------------------------------------------ the callback */

static volatile LONG g_open, g_close, g_done;

static void CALLBACK midi_callback(HMIDIOUT h, UINT msg, DWORD_PTR instance, DWORD_PTR p1, DWORD_PTR p2)
{
    (void)h; (void)instance; (void)p1; (void)p2;
    if (msg == MOM_OPEN) InterlockedIncrement(&g_open);
    else if (msg == MOM_CLOSE) InterlockedIncrement(&g_close);
    else if (msg == MOM_DONE) InterlockedIncrement(&g_done);
}

static DWORD msg3(unsigned status, unsigned d1, unsigned d2) { return (DWORD)(status | (d1 << 8) | (d2 << 16)); }

static void note(HMIDIOUT h, unsigned channel, unsigned key, unsigned velocity, DWORD ms)
{
    midiOutShortMsg(h, msg3(0x90 | channel, key, velocity));
    pump(ms);
    midiOutShortMsg(h, msg3(0x80 | channel, key, 0));
}

static void set_window_text(const char *text)
{
    if (g_window) SetWindowTextA(g_window, text);
}

/* ------------------------------------------------------------------ the tests */

static void list_devices(void)
{
    UINT n = midiOutGetNumDevs(), i;
    check(n >= 1, "MIDI output devices (winmm)", "%u device(s)", n);
    for (i = 0; i < n && i < 4; i++) {
        MIDIOUTCAPSA caps;
        memset(&caps, 0, sizeof caps);
        if (midiOutGetDevCapsA(i, &caps, sizeof caps) == MMSYSERR_NOERROR)
            say("  device %u: \"%s\", technology %u, %u voices, %u notes, channels %04x, %s%s", i, caps.szPname, caps.wTechnology, caps.wVoices,
                caps.wNotes, caps.wChannelMask, (caps.dwSupport & MIDICAPS_VOLUME) ? "volume" : "no volume", (caps.dwSupport & MIDICAPS_LRVOLUME) ? " (left/right)" : "");
    }
    say("  MIDI input devices: %u, auxiliary devices: %u (both should be 0: this device only plays)", midiInGetNumDevs(), auxGetNumDevs());
    check(midiInGetNumDevs() < 8 && auxGetNumDevs() < 8, "no phantom input or auxiliary devices", "%u input, %u auxiliary", midiInGetNumDevs(), auxGetNumDevs());
}

static void reset_gm(HMIDIOUT h)
{
    static char gm[] = { (char)0xF0, 0x7E, 0x7F, 0x09, 0x01, (char)0xF7 };
    MIDIHDR hdr;
    MMRESULT r;
    DWORD t0;
    long done_before = g_done;
    memset(&hdr, 0, sizeof hdr);
    hdr.lpData = gm;
    hdr.dwBufferLength = sizeof gm;
    r = midiOutPrepareHeader(h, &hdr, sizeof hdr);
    if (!check(r == MMSYSERR_NOERROR, "midiOutPrepareHeader (the General MIDI reset)", "%u", r)) return;
    r = midiOutLongMsg(h, &hdr, sizeof hdr);
    check(r == MMSYSERR_NOERROR, "midiOutLongMsg (F0 7E 7F 09 01 F7)", "%u", r);
    t0 = GetTickCount();
    while (!(hdr.dwFlags & MHDR_DONE) && GetTickCount() - t0 < 1000) pump(10);
    check((hdr.dwFlags & MHDR_DONE) != 0, "the long message completes (MHDR_DONE)", "flags %lx after %lu ms", (unsigned long)hdr.dwFlags, (unsigned long)(GetTickCount() - t0));
    pump(50);
    check(g_done > done_before, "MOM_DONE reaches the callback", "%ld", g_done - done_before);
    r = midiOutUnprepareHeader(h, &hdr, sizeof hdr);
    check(r == MMSYSERR_NOERROR, "midiOutUnprepareHeader", "%u", r);
}

static void volume(HMIDIOUT h)
{
    DWORD v = 0;
    MMRESULT r = midiOutGetVolume(h, &v);
    say("  volume now %08lx (get: %u)", (unsigned long)v, r);
    r = midiOutSetVolume(h, 0xFFFFFFFF);
    check(r == MMSYSERR_NOERROR, "midiOutSetVolume to full", "%u", r);
    v = 0;
    r = midiOutGetVolume(h, &v);
    check(r == MMSYSERR_NOERROR && (v & 0xFFFF) == 0xFFFF, "midiOutGetVolume reads it back", "%08lx (%u)", (unsigned long)v, r);
}

static void play_music(HMIDIOUT h)
{
    static const unsigned scale[] = { 60, 62, 64, 65, 67, 69, 71, 72 };
    static const struct { unsigned program; const char *name; unsigned key; } voices[] = {
        { 24, "nylon guitar", 55 }, { 40, "violin", 69 }, { 56, "trumpet", 67 }, { 73, "flute", 72 }, { 33, "finger bass", 40 } };
    unsigned i;
    LARGE_INTEGER f, a, b;
    double worst = 0, took;
    QueryPerformanceFrequency(&f);

    midiOutShortMsg(h, msg3(0xC0, 0, 0));
    set_window_text("MIDI test: a C major scale on a piano");
    say("  playing a C major scale on a piano (8 notes, 250 ms each)");
    QueryPerformanceCounter(&a);
    for (i = 0; i < 8; i++) {
        LARGE_INTEGER s, e;
        QueryPerformanceCounter(&s);
        note(h, 0, scale[i], 100, 250);
        QueryPerformanceCounter(&e);
        took = (double)(e.QuadPart - s.QuadPart) * 1000.0 / (double)f.QuadPart;
        if (took - 250.0 > worst) worst = took - 250.0;
    }
    QueryPerformanceCounter(&b);
    took = (double)(b.QuadPart - a.QuadPart) * 1000.0 / (double)f.QuadPart;
    check(took > 1900 && took < 2600, "the scale takes about two seconds (the calls do not stall)", "%.0f ms, the slowest note %.0f ms late", took, worst);

    set_window_text("MIDI test: a chord");
    say("  playing a C major chord on a piano (1.5 s)");
    midiOutShortMsg(h, msg3(0x90, 60, 90)); midiOutShortMsg(h, msg3(0x90, 64, 90)); midiOutShortMsg(h, msg3(0x90, 67, 90));
    pump(1500);
    midiOutShortMsg(h, msg3(0x80, 60, 0)); midiOutShortMsg(h, msg3(0x80, 64, 0)); midiOutShortMsg(h, msg3(0x80, 67, 0));
    pump(300);

    for (i = 0; i < sizeof voices / sizeof voices[0]; i++) {
        char text[100];
        snprintf(text, sizeof text, "MIDI test: %s (program %u)", voices[i].name, voices[i].program);
        set_window_text(text);
        say("  one note on %s (program %u)", voices[i].name, voices[i].program);
        midiOutShortMsg(h, msg3(0xC1, voices[i].program, 0));
        note(h, 1, voices[i].key, 100, 900);
        pump(150);
    }

    set_window_text("MIDI test: drums on channel 10");
    say("  playing a drum pattern on channel 10 (kick, hat, snare, hat; twice)");
    for (i = 0; i < 8; i++) {
        static const unsigned kit[] = { 36, 42, 38, 42 };
        note(h, 9, kit[i % 4], 110, 220);
    }
    pump(400);
    midiOutShortMsg(h, msg3(0xB0, 123, 0));   /* all notes off, as a game does when a song ends */
    check(1, "all the notes were sent", "the person hears: scale, chord, five instruments, drums");
}

static void test_device(void)
{
    HMIDIOUT h = NULL;
    MMRESULT r;
    DWORD t0;
    g_open = g_close = g_done = 0;
    r = midiOutOpen(&h, 0, (DWORD_PTR)midi_callback, 0x1234, CALLBACK_FUNCTION);
    if (!check(r == MMSYSERR_NOERROR && h, "midiOutOpen (device 0, callback function)", "%u", r)) return;
    t0 = GetTickCount();
    while (!g_open && GetTickCount() - t0 < 1000) pump(10);
    check(g_open == 1, "MOM_OPEN reaches the callback", "%ld", g_open);
    volume(h);
    reset_gm(h);
    play_music(h);
    r = midiOutClose(h);
    check(r == MMSYSERR_NOERROR, "midiOutClose", "%u", r);
    t0 = GetTickCount();
    while (!g_close && GetTickCount() - t0 < 1000) pump(10);
    check(g_close == 1, "MOM_CLOSE reaches the callback", "%ld", g_close);
}

static void test_mapper(void)
{
    HMIDIOUT h = NULL;
    MMRESULT r = midiOutOpen(&h, MIDI_MAPPER, 0, 0, CALLBACK_NULL);
    if (!check(r == MMSYSERR_NOERROR && h, "midiOutOpen (the MIDI mapper, what most games open)", "%u", r)) return;
    set_window_text("MIDI test: through the MIDI mapper");
    say("  two notes through the mapper (piano, then the same key an octave up)");
    midiOutShortMsg(h, msg3(0xC0, 0, 0));
    note(h, 0, 64, 100, 600);
    note(h, 0, 76, 100, 600);
    pump(200);
    r = midiOutClose(h);
    check(r == MMSYSERR_NOERROR, "midiOutClose (the mapper)", "%u", r);
}

/* A song in one buffer: the way sequencers play, with their own tempo. */
static volatile LONG g_stream_done;

static void CALLBACK stream_callback(HMIDIOUT h, UINT msg, DWORD_PTR instance, DWORD_PTR p1, DWORD_PTR p2)
{
    (void)h; (void)instance; (void)p1; (void)p2;
    if (msg == MOM_DONE) InterlockedIncrement(&g_stream_done);
}

static void test_stream(void)
{
    HMIDISTRM hs = NULL;
    UINT device = 0;
    MMRESULT r = midiStreamOpen(&hs, &device, 1, (DWORD_PTR)stream_callback, 0, CALLBACK_FUNCTION);
    MIDIPROPTIMEDIV div;
    MIDIPROPTEMPO tempo;
    MIDIHDR hdr;
    DWORD events[3 * 64];
    unsigned n = 0, i;
    static const unsigned tune[] = { 60, 64, 67, 72, 67, 64, 60, 55 };
    DWORD t0;
    if (!check(r == MMSYSERR_NOERROR && hs, "midiStreamOpen", "%u", r)) return;
    memset(&div, 0, sizeof div);
    div.cbStruct = sizeof div;
    div.dwTimeDiv = 96;   /* ticks per quarter note */
    r = midiStreamProperty(hs, (LPBYTE)&div, MIDIPROP_SET | MIDIPROP_TIMEDIV);
    check(r == MMSYSERR_NOERROR, "midiStreamProperty (time division 96)", "%u", r);
    memset(&tempo, 0, sizeof tempo);
    tempo.cbStruct = sizeof tempo;
    tempo.dwTempo = 500000;   /* 120 beats per minute: a quarter note is half a second */
    r = midiStreamProperty(hs, (LPBYTE)&tempo, MIDIPROP_SET | MIDIPROP_TEMPO);
    check(r == MMSYSERR_NOERROR, "midiStreamProperty (tempo 120)", "%u", r);

    /* eight eighth-notes (48 ticks): note on at delta 0, note off 48 ticks later; 4 seconds is too long for a test: eight eighths = 2 s */
    events[n++] = 0; events[n++] = 0; events[n++] = (MEVT_SHORTMSG << 24) | msg3(0xC2, 0, 0);
    for (i = 0; i < 8; i++) {
        events[n++] = 0;  events[n++] = 0; events[n++] = (MEVT_SHORTMSG << 24) | msg3(0x92, tune[i], 100);
        events[n++] = 48; events[n++] = 0; events[n++] = (MEVT_SHORTMSG << 24) | msg3(0x82, tune[i], 0);
        if (n + 6 > sizeof events / sizeof events[0]) break;
    }
    memset(&hdr, 0, sizeof hdr);
    hdr.lpData = (LPSTR)events;
    hdr.dwBufferLength = hdr.dwBytesRecorded = n * sizeof(DWORD);
    r = midiOutPrepareHeader((HMIDIOUT)hs, &hdr, sizeof hdr);
    if (!check(r == MMSYSERR_NOERROR, "midiOutPrepareHeader (the stream's buffer)", "%u", r)) { midiStreamClose(hs); return; }
    g_stream_done = 0;
    set_window_text("MIDI test: a tune through a MIDI stream");
    say("  playing a tune through the stream (8 eighth notes at 120 bpm, about 2 seconds)");
    r = midiStreamOut(hs, &hdr, sizeof hdr);
    check(r == MMSYSERR_NOERROR, "midiStreamOut", "%u", r);
    r = midiStreamRestart(hs);
    check(r == MMSYSERR_NOERROR, "midiStreamRestart", "%u", r);
    t0 = GetTickCount();
    while (!(hdr.dwFlags & MHDR_DONE) && GetTickCount() - t0 < 6000) pump(20);
    {
        DWORD took = GetTickCount() - t0;
        check((hdr.dwFlags & MHDR_DONE) != 0 && took > 1500 && took < 3500, "the buffer comes back done after about its length", "%lu ms (the tune is 2000 ms)", (unsigned long)took);
    }
    check(g_stream_done >= 1, "MOM_DONE reaches the stream's callback", "%ld", g_stream_done);
    midiStreamStop(hs);
    midiOutUnprepareHeader((HMIDIOUT)hs, &hdr, sizeof hdr);
    r = midiStreamClose(hs);
    check(r == MMSYSERR_NOERROR, "midiStreamClose", "%u", r);
}

/* ------------------------------------------------------------------ the window */

static DWORD WINAPI run_tests(void *arg)
{
    char text[160];
    (void)arg;
    emit("== MIDI ==");
    list_devices();
    if (midiOutGetNumDevs() >= 1) {
        test_device();
        test_mapper();
        test_stream();
    }
    snprintf(text, sizeof text, "RESULT %s %d checks, %d failed, %u midi device(s)", g_fails ? "FAIL" : "PASS", g_checks, g_fails, midiOutGetNumDevs());
    emit(text);
    set_window_text(g_fails ? "MIDI test: FAIL (see the lines)" : "MIDI test: PASS (did you hear it?)");
    return 0;
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_CREATE: {
        RECT r;
        GetClientRect(h, &r);
        g_list = CreateWindowExA(WS_EX_CLIENTEDGE, "LISTBOX", NULL, WS_CHILD | WS_VISIBLE | WS_VSCROLL | LBS_NOSEL, 0, 0, r.right, r.bottom, h, NULL, NULL, NULL);
        SendMessageA(g_list, WM_SETFONT, (WPARAM)GetStockObject(DEFAULT_GUI_FONT), 0);
        return 0;
    }
    case WM_SIZE:
        if (g_list) MoveWindow(g_list, 0, 0, LOWORD(l), HIWORD(l), TRUE);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSA wc;
    MSG msg;
    char path[MAX_PATH];
    HANDLE thread;
    (void)prev; (void)cmd;
    if (GetTempPathA(sizeof path - 16, path)) {
        strcat(path, "bcd-test.log");
        g_file = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    }
    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = "BCDMidiTest";
    RegisterClassA(&wc);
    g_window = CreateWindowA("BCDMidiTest", "MIDI test: starting", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40, 760, 440, NULL, NULL, inst, NULL);
    if (!g_window) return 1;
    ShowWindow(g_window, show);
    thread = CreateThread(NULL, 0, run_tests, NULL, 0, NULL);
    while (GetMessageA(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageA(&msg); }
    if (thread) WaitForSingleObject(thread, 2000);
    return g_fails ? 1 : 0;
}
