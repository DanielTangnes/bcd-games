// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// bcd-helper-x64.exe (round 604): the start helper a game's start script calls (core.h says what it is for and what it never does).
//
//   bcd-helper-x64.exe wait <seconds>        sleeps, then ends (the script's "delay before the game starts")
//   bcd-helper-x64.exe supervise <file>      the second program and the window rules, until the game has ended
//
// A Windows program of BCD's own, built with llvm-mingw like bcd-runtimes-x64.exe (tools/build-bcd-helper.sh) and copied by the app into
// C:\bcd-games next to the start script before a start that needs it. It opens no window and writes no file; a line goes to the debug
// output when a rule acts or a program is closed (the engine mirrors the session's debug output into BCD's log).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include "core.h"

static unsigned os_now(void *u) { (void)u; return (unsigned)GetTickCount64(); }
static void os_sleep(void *u, unsigned ms) { (void)u; Sleep(ms); }

static char g_log[260];

/* A line to the debug output and, when the start file names one, to its text file (at most 64 KB of it): drive_c is in Files, so a
 * player or the lead can read what the helper did without a debugger. */
static void say(const char *line)
{
    OutputDebugStringA(line);
    if (g_log[0]) {
        HANDLE h = CreateFileA(g_log, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            char text[300];
            DWORD done, size = GetFileSize(h, NULL);
            ULONGLONG ms = GetTickCount64();
            int n = snprintf(text, sizeof text, "[%llu.%03llu s] %s", ms / 1000, ms % 1000, line);
            if (size != INVALID_FILE_SIZE && size < 64 * 1024 && n > 0) WriteFile(h, text, (DWORD)n, &done, NULL);
            CloseHandle(h);
        }
    }
}

static int os_processes(void *u, hr_proc *out, int max)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32 e;
    int n = 0;
    (void)u;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    e.dwSize = sizeof e;
    for (BOOL ok = Process32First(snap, &e); ok && n < max; ok = Process32Next(snap, &e)) {
        hr_proc *p = &out[n];
        HANDLE h;
        p->pid = e.th32ProcessID;
        hr_lower_copy(p->name, sizeof p->name, e.szExeFile);
        p->dir[0] = 0;
        h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, e.th32ProcessID);
        if (h) {
            char path[MAX_PATH];
            DWORD len = sizeof path;
            if (QueryFullProcessImageNameA(h, 0, path, &len) && len > 0) {
                char *slash = strrchr(path, '\\');
                if (slash) *slash = 0;
                hr_lower_copy(p->dir, sizeof p->dir, path);
            }
            CloseHandle(h);
        }
        n++;
    }
    CloseHandle(snap);
    return n;
}

typedef struct { hr_win *out; int max, n; } win_list;

static BOOL CALLBACK collect_window(HWND hwnd, LPARAM lparam)
{
    win_list *list = (win_list *)lparam;
    hr_win *w;
    wchar_t title[256];
    DWORD pid = 0;
    if (list->n >= list->max || !IsWindowVisible(hwnd)) return TRUE;
    w = &list->out[list->n];
    w->handle = (hr_u64)(ULONG_PTR)hwnd;
    GetWindowThreadProcessId(hwnd, &pid);
    w->pid = pid;
    w->title[0] = 0;
    if (GetWindowTextW(hwnd, title, 256) > 0) WideCharToMultiByte(CP_UTF8, 0, title, -1, w->title, (int)sizeof w->title, NULL, NULL);
    w->title[sizeof w->title - 1] = 0;
    if (!GetClassNameA(hwnd, w->cls, (int)sizeof w->cls)) w->cls[0] = 0;
    if (!w->title[0] && !w->cls[0]) return TRUE;
    list->n++;
    return TRUE;
}

static int os_windows(void *u, hr_win *out, int max)
{
    win_list list = { out, max, 0 };
    (void)u;
    EnumWindows(collect_window, (LPARAM)&list);
    return list.n;
}

static void os_apply(void *u, hr_u64 handle, hr_action action)
{
    HWND hwnd = (HWND)(ULONG_PTR)handle;
    (void)u;
    if (!IsWindow(hwnd)) return;
    switch (action) {
    case HR_RAISE:
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        say("[bcd-helper] raised a window\n");
        break;
    case HR_MINIMIZE_RESTORE:
        ShowWindow(hwnd, SW_MINIMIZE);
        Sleep(300);
        ShowWindow(hwnd, SW_RESTORE);
        say("[bcd-helper] minimised and restored a window\n");
        break;
    case HR_OPAQUE: {
        LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex & ~(LONG_PTR)WS_EX_TRANSPARENT);
        if (ex & WS_EX_LAYERED) SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
        say("[bcd-helper] made a window opaque\n");
        break;
    }
    default: break;
    }
}

static void os_terminate(void *u, unsigned pid)
{
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    (void)u;
    if (!h) return;
    TerminateProcess(h, 0);
    CloseHandle(h);
    say("[bcd-helper] closed the second program\n");
}

static char *read_file(const char *path)
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD size, got = 0;
    char *text;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    size = GetFileSize(h, NULL);
    if (size == INVALID_FILE_SIZE || size > 64 * 1024) { CloseHandle(h); return NULL; }
    text = (char *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, size + 1);
    if (text && !ReadFile(h, text, size, &got, NULL)) { HeapFree(GetProcessHeap(), 0, text); text = NULL; }
    CloseHandle(h);
    return text;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    int argc = __argc;
    char **argv = __argv;
    (void)inst; (void)prev; (void)cmd; (void)show;
    if (argc >= 3 && !strcmp(argv[1], "wait")) {
        long seconds = strtol(argv[2], NULL, 10);
        if (seconds > 0 && seconds <= 300) Sleep((DWORD)seconds * 1000u);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "supervise")) {
        static hr_config config;
        static hr_state state;
        char err[160] = "";
        char *text = read_file(argv[2]);
        hr_os os = { NULL, os_now, os_sleep, os_processes, os_windows, os_apply, os_terminate, GetCurrentProcessId() };
        if (!text) return 2;
        if (hr_parse_config(text, &config, err, sizeof err) != 0) { { char line[240]; snprintf(line, sizeof line, "[bcd-helper] the start file is not valid: %s\n", err); say(line); } return 3; }
        HeapFree(GetProcessHeap(), 0, text);
        strcpy(g_log, config.log);
        hr_init(&state, &os);
        say("[bcd-helper] supervising\n");
        while (!hr_step(&state, &config, &os)) Sleep(500);
        say("[bcd-helper] done\n");
        return 0;
    }
    return 1;
}
