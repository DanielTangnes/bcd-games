// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// BCD's sound test (round 602): a left, a right and a centre tone through XAudio2 and then through DirectSound. One source,
// two programs: sound-test-x64.exe (64-bit) and sound-test-x86.exe (32-bit, as most DirectSound games are).
//
// The tone (bcdstats.h, bt_tone_stereo): three seconds of 16-bit stereo. Second 1 is a low tone (440 Hz) in the LEFT channel
// only, second 2 a higher tone (660 Hz) in the RIGHT channel only, second 3 both at once. The window says which one is
// playing, so a person can check that the left tone comes out on the left and the right one on the right.
//
// What the program can check by itself, as PASS or FAIL with numbers:
//   XAudio2 (2.9, then 2.8):  XAudio2Create, the mastering voice (channels and sample rate of the output device), a source
//     voice for 48 kHz stereo PCM, the buffer accepted, Start, and the samples played advancing at real time until all
//     144000 are played (a sound system that plays nothing, or a hundred times too fast, fails here);
//   DirectSound:  DirectSoundCreate8, SetCooperativeLevel, GetCaps, a 44.1 kHz stereo secondary buffer written with Lock and
//     Unlock, Play, the play cursor advancing to the end in about three seconds, and a second, mono buffer panned hard
//     left and then hard right (SetPan, read back with GetPan).
// What it cannot check is that the sound reaches a speaker: that is the person's ears.
//
// Every line goes to the window and to the session log ("[bcd-test] sound (64-bit): PASS|FAIL ..."). R plays it again.

#define COBJMACROS
#include "bcdtest.h"
#include "bcdstats.h"
#include <mmsystem.h>
#include <dsound.h>
#include <xaudio2.h>

#ifndef XAUDIO2_DEFAULT_PROCESSOR
#define XAUDIO2_DEFAULT_PROCESSOR 0x00000001
#endif

typedef HRESULT (WINAPI *xa2create_fn)(IXAudio2 **, UINT32, XAUDIO2_PROCESSOR);
typedef HRESULT (WINAPI *dscreate8_fn)(LPCGUID, LPDIRECTSOUND8 *, LPUNKNOWN);

static double g_xa_secs = -1, g_ds_secs = -1;   /* seconds the 3 s of audio took, -1 when it did not play */
static unsigned g_out_channels, g_out_rate;
static const char *g_now = "";
static char g_big[96];

static void paint_hook(bt_panel *p, HDC dc, int w, int h)
{
    HFONT big = CreateFontA(-34, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE, ANSI_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, VARIABLE_PITCH | FF_SWISS, "Arial");
    HGDIOBJ old = SelectObject(dc, big);
    RECT r = { 8, 6, w - 8, h };
    HBRUSH side;
    RECT lbar = { 0, 0, 14, h }, rbar = { w - 14, 0, w, h };

    (void)p;
    /* a bar on the side the tone comes from */
    side = CreateSolidBrush(RGB(90, 160, 255));
    if (strstr(g_now, "LEFT") || strstr(g_now, "BOTH")) FillRect(dc, &lbar, side);
    if (strstr(g_now, "RIGHT") || strstr(g_now, "BOTH")) FillRect(dc, &rbar, side);
    DeleteObject(side);
    SetTextColor(dc, RGB(255, 235, 150));
    DrawTextA(dc, g_big, -1, &r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject(dc, old);
    DeleteObject(big);
}

/* The segment of the three-second tone that is playing at `t` seconds. */
static void announce(bt_panel *pn, double t)
{
    const char *now = t < 1.0 ? "LEFT" : t < 2.0 ? "RIGHT" : t < 3.0 ? "BOTH" : "";
    if (strcmp(now, g_now) != 0) {
        g_now = now;
        snprintf(g_big, sizeof g_big, "%s", now[0] ? (strcmp(now, "LEFT") == 0 ? "LEFT  (low tone, 440 Hz)" : strcmp(now, "RIGHT") == 0 ? "RIGHT  (high tone, 660 Hz)" : "BOTH  (low + high)") : "");
        InvalidateRect(pn->hwnd, NULL, FALSE);
    }
}

static int16_t g_tone48[3 * 48000 * 2], g_tone44[3 * 44100 * 2], g_mono[44100 * 2];

/* ------------------------------------------------------------------ the sound devices Windows lists */

static void list_devices(bt_panel *pn)
{
    UINT n = waveOutGetNumDevs(), i;
    bt_report(pn, n > 0, "audio output devices (winmm)", "%u device(s)", n);
    for (i = 0; i < n && i < 3; i++) {
        WAVEOUTCAPSA caps;
        if (waveOutGetDevCapsA(i, &caps, sizeof caps) == MMSYSERR_NOERROR)
            bt_note(pn, BT_INFO, "  device %u: \"%s\", %u channel(s), formats %08lx", i, caps.szPname, caps.wChannels, (unsigned long)caps.dwFormats);
    }
}

/* ------------------------------------------------------------------ XAudio2 */

static void test_xaudio2(bt_panel *pn)
{
    static const char *const dlls[] = { "xaudio2_9.dll", "xaudio2_8.dll" };
    xa2create_fn create = NULL;
    HMODULE m = NULL;
    IXAudio2 *xa = NULL;
    IXAudio2MasteringVoice *master = NULL;
    IXAudio2SourceVoice *src = NULL;
    XAUDIO2_VOICE_DETAILS vd;
    WAVEFORMATEX wf;
    XAUDIO2_BUFFER buf;
    XAUDIO2_VOICE_STATE st;
    HRESULT hr;
    double t0, el = 0;
    unsigned long long played = 0;
    int i, finished = 0;

    bt_note(pn, BT_HEAD, "== XAudio2 ==");
    for (i = 0; i < 2 && !create; i++) {
        m = LoadLibraryA(dlls[i]);
        if (m) create = (xa2create_fn)GetProcAddress(m, "XAudio2Create");
        if (create) bt_note(pn, BT_INFO, "  using %s", dlls[i]);
    }
    if (!create) { bt_report(pn, 0, "XAudio2 library", "neither xaudio2_9.dll nor xaudio2_8.dll has XAudio2Create"); return; }
    hr = create(&xa, 0, XAUDIO2_DEFAULT_PROCESSOR);
    if (!bt_report(pn, SUCCEEDED(hr) && xa, "XAudio2Create", "%s", bt_hr(hr))) return;
    hr = IXAudio2_CreateMasteringVoice(xa, &master, XAUDIO2_DEFAULT_CHANNELS, XAUDIO2_DEFAULT_SAMPLERATE, 0, NULL, NULL, AudioCategory_GameEffects);
    if (!bt_report(pn, SUCCEEDED(hr) && master, "CreateMasteringVoice", "%s", bt_hr(hr))) { IXAudio2_Release(xa); return; }
    memset(&vd, 0, sizeof vd);
    IXAudio2MasteringVoice_GetVoiceDetails(master, &vd);
    g_out_channels = vd.InputChannels;
    g_out_rate = vd.InputSampleRate;
    bt_report(pn, vd.InputChannels >= 1 && vd.InputSampleRate >= 8000, "output device format", "%u channel(s) at %u Hz", vd.InputChannels, vd.InputSampleRate);

    memset(&wf, 0, sizeof wf);
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = 2;
    wf.nSamplesPerSec = 48000;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = (WORD)(wf.nChannels * wf.wBitsPerSample / 8);
    wf.nAvgBytesPerSec = wf.nSamplesPerSec * wf.nBlockAlign;
    hr = IXAudio2_CreateSourceVoice(xa, &src, &wf, 0, XAUDIO2_DEFAULT_FREQ_RATIO, NULL, NULL, NULL);
    if (!bt_report(pn, SUCCEEDED(hr) && src, "CreateSourceVoice (48 kHz, 16-bit, stereo)", "%s", bt_hr(hr))) goto out;

    memset(&buf, 0, sizeof buf);
    buf.Flags = XAUDIO2_END_OF_STREAM;
    buf.AudioBytes = sizeof g_tone48;
    buf.pAudioData = (const BYTE *)g_tone48;
    hr = IXAudio2SourceVoice_SubmitSourceBuffer(src, &buf, NULL);
    if (!bt_report(pn, SUCCEEDED(hr), "SubmitSourceBuffer (3 s)", "%s, %lu bytes", bt_hr(hr), (unsigned long)buf.AudioBytes)) goto out;

    hr = IXAudio2SourceVoice_Start(src, 0, XAUDIO2_COMMIT_NOW);
    if (!bt_report(pn, SUCCEEDED(hr), "Start", "%s", bt_hr(hr))) goto out;
    t0 = bt_now();
    for (;;) {
        el = bt_now() - t0;
        announce(pn, el);
        memset(&st, 0, sizeof st);
        IXAudio2SourceVoice_GetState(src, &st, 0);
        played = st.SamplesPlayed;
        if (st.BuffersQueued == 0 && el > 0.2) { finished = 1; break; }
        if (el > 7.0 || !bt_pump(pn)) break;
        Sleep(15);
    }
    announce(pn, 99.0);
    if (finished) g_xa_secs = el;
    bt_report(pn, finished && played >= 143000 && el >= 2.5 && el <= 5.5, "played in real time",
              "%llu of 144000 samples played, buffers %s after %.2f s (about 3.0 s expected)", played, finished ? "done" : "NOT done", el);
out:
    if (src) { IXAudio2SourceVoice_Stop(src, 0, XAUDIO2_COMMIT_NOW); IXAudio2SourceVoice_DestroyVoice(src); }
    if (master) IXAudio2MasteringVoice_DestroyVoice(master);
    if (xa) IXAudio2_Release(xa);
}

/* ------------------------------------------------------------------ DirectSound */

static LPDIRECTSOUNDBUFFER make_buffer(LPDIRECTSOUND8 ds, int channels, int rate, int bytes, DWORD flags, const void *data, HRESULT *hr)
{
    WAVEFORMATEX wf;
    DSBUFFERDESC d;
    LPDIRECTSOUNDBUFFER b = NULL;
    void *p1 = NULL, *p2 = NULL;
    DWORD n1 = 0, n2 = 0;

    memset(&wf, 0, sizeof wf);
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = (WORD)channels;
    wf.nSamplesPerSec = (DWORD)rate;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = (WORD)(channels * 2);
    wf.nAvgBytesPerSec = (DWORD)(rate * wf.nBlockAlign);
    memset(&d, 0, sizeof d);
    d.dwSize = sizeof d;
    d.dwFlags = flags;
    d.dwBufferBytes = (DWORD)bytes;
    d.lpwfxFormat = &wf;
    *hr = IDirectSound8_CreateSoundBuffer(ds, &d, &b, NULL);
    if (FAILED(*hr) || !b) return NULL;
    *hr = IDirectSoundBuffer_Lock(b, 0, (DWORD)bytes, &p1, &n1, &p2, &n2, 0);
    if (FAILED(*hr)) { IDirectSoundBuffer_Release(b); return NULL; }
    memcpy(p1, data, n1 < (DWORD)bytes ? n1 : (DWORD)bytes);
    IDirectSoundBuffer_Unlock(b, p1, n1, p2, n2);
    return b;
}

static void test_dsound(bt_panel *pn)
{
    HMODULE m = LoadLibraryA("dsound.dll");
    dscreate8_fn create = m ? (dscreate8_fn)GetProcAddress(m, "DirectSoundCreate8") : NULL;
    LPDIRECTSOUND8 ds = NULL;
    LPDIRECTSOUNDBUFFER b = NULL, mono = NULL;
    DSCAPS caps;
    HRESULT hr;
    double t0, el = 0;
    DWORD play_cursor = 0, max_cursor = 0, status = 0;
    const DWORD bytes = sizeof g_tone44;

    bt_note(pn, BT_HEAD, "== DirectSound ==");
    if (!create) { bt_report(pn, 0, "dsound.dll", "no DirectSoundCreate8 (LoadLibrary %lu)", GetLastError()); return; }
    hr = create(NULL, &ds, NULL);
    if (!bt_report(pn, SUCCEEDED(hr) && ds, "DirectSoundCreate8", "%s", bt_hr(hr))) return;
    hr = IDirectSound8_SetCooperativeLevel(ds, pn->hwnd, DSSCL_PRIORITY);
    bt_report(pn, SUCCEEDED(hr), "SetCooperativeLevel(PRIORITY)", "%s", bt_hr(hr));
    memset(&caps, 0, sizeof caps);
    caps.dwSize = sizeof caps;
    hr = IDirectSound8_GetCaps(ds, &caps);
    bt_report(pn, SUCCEEDED(hr), "GetCaps", "%s, flags %08lx, secondary rates %lu to %lu Hz, %lu primary buffer(s)", bt_hr(hr), (unsigned long)caps.dwFlags,
              (unsigned long)caps.dwMinSecondarySampleRate, (unsigned long)caps.dwMaxSecondarySampleRate, (unsigned long)caps.dwPrimaryBuffers);

    b = make_buffer(ds, 2, 44100, (int)bytes, DSBCAPS_GETCURRENTPOSITION2 | DSBCAPS_GLOBALFOCUS | DSBCAPS_CTRLVOLUME, g_tone44, &hr);
    if (!bt_report(pn, b != NULL, "secondary buffer (44.1 kHz, 16-bit, stereo, 3 s), Lock + write + Unlock", "%s", bt_hr(hr))) goto out;
    hr = IDirectSoundBuffer_Play(b, 0, 0, 0);
    if (!bt_report(pn, SUCCEEDED(hr), "Play", "%s", bt_hr(hr))) goto out;
    t0 = bt_now();
    for (;;) {
        el = bt_now() - t0;
        announce(pn, el);
        status = 0;
        IDirectSoundBuffer_GetStatus(b, &status);
        if (SUCCEEDED(IDirectSoundBuffer_GetCurrentPosition(b, &play_cursor, NULL)) && play_cursor > max_cursor) max_cursor = play_cursor;
        if (!(status & DSBSTATUS_PLAYING) && el > 0.2) break;
        if (el > 7.0 || !bt_pump(pn)) break;
        Sleep(15);
    }
    announce(pn, 99.0);
    if (!(status & DSBSTATUS_PLAYING)) g_ds_secs = el;
    bt_report(pn, !(status & DSBSTATUS_PLAYING) && max_cursor >= bytes * 9 / 10 && el >= 2.5 && el <= 5.5, "played in real time",
              "the play cursor reached %lu of %lu bytes, buffer %s after %.2f s (about 3.0 s expected)", (unsigned long)max_cursor, (unsigned long)bytes,
              (status & DSBSTATUS_PLAYING) ? "still playing" : "stopped", el);

    /* a mono buffer panned hard left, then hard right */
    mono = make_buffer(ds, 1, 44100, (int)sizeof g_mono, DSBCAPS_CTRLPAN | DSBCAPS_CTRLVOLUME | DSBCAPS_GLOBALFOCUS, g_mono, &hr);
    if (!bt_report(pn, mono != NULL, "mono buffer with pan control (44.1 kHz, 2 s)", "%s", bt_hr(hr))) goto out;
    {
        LONG pan_set[2] = { -10000, 10000 }, got = 0;
        int k;
        for (k = 0; k < 2; k++) {
            HRESULT ph = IDirectSoundBuffer_SetPan(mono, pan_set[k]);
            HRESULT gh = IDirectSoundBuffer_GetPan(mono, &got);
            bt_report(pn, SUCCEEDED(ph) && SUCCEEDED(gh) && got == pan_set[k], k == 0 ? "SetPan hard left" : "SetPan hard right", "set %ld, GetPan says %ld (%s, %s)", (long)pan_set[k], (long)got, bt_hr(ph), bt_hr(gh));
            g_now = "";
            snprintf(g_big, sizeof g_big, "%s", k == 0 ? "PAN: LEFT only" : "PAN: RIGHT only");
            g_now = k == 0 ? "LEFT" : "RIGHT";
            InvalidateRect(pn->hwnd, NULL, FALSE);
            IDirectSoundBuffer_SetCurrentPosition(mono, 0);
            IDirectSoundBuffer_Play(mono, 0, 0, 0);
            bt_sleep(pn, 1000);
            IDirectSoundBuffer_Stop(mono);
        }
        g_now = "";
        g_big[0] = 0;
        InvalidateRect(pn->hwnd, NULL, FALSE);
    }
out:
    if (mono) IDirectSoundBuffer_Release(mono);
    if (b) { IDirectSoundBuffer_Stop(b); IDirectSoundBuffer_Release(b); }
    if (ds) IDirectSound8_Release(ds);
}

/* ------------------------------------------------------------------ main */

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    bt_panel *pn;
    int again;

    (void)inst; (void)prev; (void)cmd; (void)show;
    bt_init("sound");
    bt_tone_stereo(g_tone48, 48000);
    bt_tone_stereo(g_tone44, 44100);
    bt_tone_mono(g_mono, 44100, 2);
    pn = bt_panel_new("sound test", 720, 540);
    if (!pn) { bt_check(0, "window", "could not be created"); bt_result(); return 1; }
    pn->hook_h = 64;
    pn->paint_hook = paint_hook;
    bt_panel_button(pn, 'R', "R: play again");
    bt_panel_button(pn, 'Q', "Close");
    snprintf(g_big, sizeof g_big, "Sound test: turn the volume up");

    do {
        int id;
        again = 0;
        bt_panel_clear(pn);
        bt_g.checks = bt_g.fails = 0;
        g_xa_secs = g_ds_secs = -1;
        bt_panel_title(pn, "sound test", "");
        bt_note(pn, BT_INFO, "Three seconds a time: LEFT speaker (low tone), RIGHT speaker (high tone), then both.");
        list_devices(pn);
        test_xaudio2(pn);
        test_dsound(pn);
        bt_headline("3.00 s of audio played in %.2f s through XAudio2 and in %.2f s through DirectSound (-1 = did not play); output device %u channel(s) at %u Hz", g_xa_secs, g_ds_secs,
                    g_out_channels, g_out_rate);
        bt_result();
        bt_panel_title(pn, "sound test", bt_g.head);
        snprintf(g_big, sizeof g_big, "%s", bt_g.fails ? "Some checks FAILED" : "All checks passed");
        bt_panel_line(pn, bt_g.fails ? BT_FAIL : BT_PASS, "RESULT %s: %d of %d checks passed. Did you hear left, right, both? R plays again; Send Log keeps this.", bt_g.fails ? "FAIL" : "PASS",
                      bt_g.checks - bt_g.fails, bt_g.checks);
        id = bt_wait_click(pn);
        if (id == 'R') again = 1;
        if (id == 'Q') PostMessageA(pn->hwnd, WM_CLOSE, 0, 0);
    } while (again && !pn->closed);
    return 0;
}
