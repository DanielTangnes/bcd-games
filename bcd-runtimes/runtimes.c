// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// runtimes.c: BCD's runtime installer, one Windows program told what to do by its first argument. The Wine desktop's Start menu
// (app/Madeira/BCDStartMenu.c, folder "BCD Runtimes") has one entry for each:
//
//   bcd-runtimes-x64.exe xna       Microsoft XNA Framework Redistributable 4.0   (msiexec /i ... /qn)
//   bcd-runtimes-x64.exe physx     NVIDIA PhysX System Software 9.21.0713        (unpacked with BCD's 7z.exe, installed from NVIDIA's manifest: physx.h)
//   bcd-runtimes-x64.exe openal    OpenAL (oalinst.exe /s from Creative's oalinst.zip)
//   bcd-runtimes-x64.exe dx2010    DirectX End-User Runtimes June 2010: only the DLLs BCD does not carry (cabs.h)
//   bcd-runtimes-x64.exe status    which of them are installed, and what is not a download at all (Media Foundation)
//   options: --install (start at once, without waiting for the button), --keep (keep the downloaded file), --file <path> (use a copy
//   of the vendor's file that is on this device already; it must match the SHA-256 and size below just the same)
//
// Nothing here ships in BCD's package. The program downloads the vendor's own file when the person presses the button, from the one
// HTTPS host core.h names for it (redirects are followed by hand and must stay on that host), refuses anything that is not exactly
// the file whose size and SHA-256 are pinned in core.h, and installs it in the way its table row says. A file that fails the check
// is deleted and never started. What is written where is in core.h/physx.h/cabs.h; nothing outside the Windows folders of the
// prefix and the vendors' own program folders is touched, and no existing DLL is ever overwritten by the DirectX runtime.
//
// Output. On screen: a window with the plan, a progress bar, the log and two buttons. In BCD's session log: a program started from
// the Start menu has no standard error (shell32 gives it a new console), so every line is written to C:\ProgramData\BCD\bcd-runtimes.log
// as well, which the engine's [guest-log] mirror copies into the session log (all lines in the plain desktop session; the RESULT
// line holds the word "failed" so that it gets through even when only lines with words like it are mirrored). Lines are also
// written to standard error when the program has one. Every run ends with one line:
//   [runtimes] RESULT <id>: PASS|WARN|FAIL|SKIP - <what happened> (<n> failed)

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <winhttp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core.h"
#include "physx.h"
#include "cabs.h"

#define APP_TITLE "BCD runtimes"
#define BASE_DIR  "C:\\ProgramData\\BCD"
#define RT_DIR    BASE_DIR "\\Runtimes"
#define LOG_FILE  BASE_DIR "\\bcd-runtimes.log"
#define SYS_DIR64 "C:\\windows\\system32"
#define SYS_DIR32 "C:\\windows\\syswow64"
#define SEVENZIP  SYS_DIR64 "\\7z.exe"

/* ================================================================== output */

static HWND g_wnd, g_info, g_status, g_edit, g_go, g_close;
static HFONT g_font_ui, g_font_mono;
static CRITICAL_SECTION g_lock;
static char *g_text;
static size_t g_len, g_cap;
static volatile LONG g_dirty;
static volatile LONG g_abort;              /* the window was closed during the download */
static volatile LONG g_busy;               /* a run is under way */
static volatile LONG g_percent = -1;       /* 0..100 for the bar; -1: busy without a number */
static char g_status_text[240];
static HANDLE g_logfile = INVALID_HANDLE_VALUE;
static int g_headless;
static HANDLE g_worker;
static const rt_runtime *g_rt;             /* NULL: the status window */
static int g_keep, g_auto;
static char g_local_file[MAX_PATH];
static int g_failed_count;
#define WM_REFRESH (WM_APP + 1)
#define WM_DONE    (WM_APP + 2)

static void emit(const char *line)
{
    char buf[1100];
    DWORD written = 0;
    size_t n = strlen(line);
    HANDLE err = GetStdHandle(STD_ERROR_HANDLE);

    if (n > 1000) n = 1000;
    memcpy(buf, "[runtimes] ", 11);
    memcpy(buf + 11, line, n);
    buf[11 + n] = '\n';
    if (err && err != INVALID_HANDLE_VALUE) WriteFile(err, buf, (DWORD)(12 + n), &written, NULL);
    if (g_logfile != INVALID_HANDLE_VALUE) WriteFile(g_logfile, buf, (DWORD)(12 + n), &written, NULL);

    EnterCriticalSection(&g_lock);
    if (g_len + n + 3 > g_cap) {
        size_t cap = g_cap ? g_cap * 2 : 8192;
        char *bigger;
        while (cap < g_len + n + 3) cap *= 2;
        bigger = (char *)realloc(g_text, cap);
        if (bigger) { g_text = bigger; g_cap = cap; }
    }
    if (g_text && g_len + n + 3 <= g_cap) {
        memcpy(g_text + g_len, buf + 11, n);
        g_len += n;
        g_text[g_len++] = '\r';
        g_text[g_len++] = '\n';
        g_text[g_len] = 0;
    }
    LeaveCriticalSection(&g_lock);
    if (g_wnd && !InterlockedExchange(&g_dirty, 1)) PostMessageA(g_wnd, WM_REFRESH, 0, 0);
}

static void say(const char *fmt, ...)
{
    char text[1400];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    emit(text);
}

static void say_ctx(void *ctx, const char *line)
{
    (void)ctx;
    emit(line);
}

static void set_status(int percent, const char *fmt, ...)
{
    va_list ap;
    EnterCriticalSection(&g_lock);
    va_start(ap, fmt);
    vsnprintf(g_status_text, sizeof g_status_text, fmt, ap);
    va_end(ap);
    LeaveCriticalSection(&g_lock);
    g_percent = percent;
    if (g_wnd && !InterlockedExchange(&g_dirty, 1)) PostMessageA(g_wnd, WM_REFRESH, 0, 0);
}

static void fail_count(void) { g_failed_count++; }

/* ================================================================== files and folders */

static int file_exists(const char *path) { return GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES; }

static int make_dirs(const char *path)
{
    char buf[MAX_PATH];
    size_t i;
    snprintf(buf, sizeof buf, "%s", path);
    for (i = 3; buf[i]; i++) {
        if (buf[i] == '\\') {
            buf[i] = 0;
            if (!CreateDirectoryA(buf, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return -1;
            buf[i] = '\\';
        }
    }
    if (!CreateDirectoryA(buf, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return -1;
    return 0;
}

/* Deletes a folder tree below the runtimes folder (only there), so a mistake in a path cannot reach anything else. */
static void remove_tree(const char *dir)
{
    char pattern[MAX_PATH], child[MAX_PATH];
    WIN32_FIND_DATAA fd;
    HANDLE h;

    if (!rt_path_below(dir, RT_DIR)) return;
    snprintf(pattern, sizeof pattern, "%s\\*", dir);
    h = FindFirstFileA(pattern, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!strcmp(fd.cFileName, ".") || !strcmp(fd.cFileName, "..")) continue;
            snprintf(child, sizeof child, "%s\\%s", dir, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) { DeleteFileA(child); RemoveDirectoryA(child); continue; }   /* never follow a link */
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) remove_tree(child);
            else { SetFileAttributesA(child, FILE_ATTRIBUTE_NORMAL); DeleteFileA(child); }
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryA(dir);
}

static int win_exists(void *ctx, const char *path) { (void)ctx; return file_exists(path); }

static int win_list(void *ctx, const char *dir, int index, char *name, size_t cap)
{
    char pattern[MAX_PATH];
    WIN32_FIND_DATAA fd;
    HANDLE h;
    int i = 0, found = 0;
    (void)ctx;
    snprintf(pattern, sizeof pattern, "%s\\*", dir);
    h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    do {
        if (!strcmp(fd.cFileName, ".") || !strcmp(fd.cFileName, "..")) continue;
        if (i++ == index) { snprintf(name, cap, "%s", fd.cFileName); found = 1; break; }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return found;
}

static const rt_fs g_fs = { win_exists, win_list, NULL };

/* ================================================================== the DLL destination of the DirectX runtime */

typedef struct { HANDLE h; char part[MAX_PATH]; } win_part;

static void *wd_begin(void *ctx, const char *final_path)
{
    win_part *p = (win_part *)calloc(1, sizeof *p);
    (void)ctx;
    if (!p) return NULL;
    snprintf(p->part, sizeof p->part, "%s.bcd-part", final_path);
    DeleteFileA(p->part);                                           /* a stale part file of a run that was cut short */
    p->h = CreateFileA(p->part, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (p->h == INVALID_HANDLE_VALUE) { free(p); return NULL; }
    return p;
}

static int wd_write(void *ctx, void *file, const void *data, size_t n)
{
    win_part *p = (win_part *)file;
    DWORD done = 0;
    (void)ctx;
    return WriteFile(p->h, data, (DWORD)n, &done, NULL) && done == n ? 0 : -1;
}

static int wd_commit(void *ctx, void *file, const char *final_path)
{
    win_part *p = (win_part *)file;
    int r;
    (void)ctx;
    if (!FlushFileBuffers(p->h)) { /* not fatal: a file system that cannot flush still has the data */ }
    CloseHandle(p->h);
    if (MoveFileExA(p->part, final_path, 0)) r = 0;                  /* no REPLACE flag: refused when the name is taken */
    else if (GetLastError() == ERROR_ALREADY_EXISTS || GetLastError() == ERROR_FILE_EXISTS) r = 1;
    else r = -1;
    if (r != 0) DeleteFileA(p->part);
    free(p);
    return r;
}

static void wd_abort(void *ctx, void *file, const char *final_path)
{
    win_part *p = (win_part *)file;
    (void)ctx; (void)final_path;
    CloseHandle(p->h);
    DeleteFileA(p->part);
    free(p);
}

typedef struct { HANDLE h; } win_src;

static int ws_read(void *ctx, u64 off, void *buf, size_t n)
{
    win_src *s = (win_src *)ctx;
    LARGE_INTEGER pos;
    DWORD got = 0;
    pos.QuadPart = (LONGLONG)off;
    if (!SetFilePointerEx(s->h, pos, NULL, FILE_BEGIN)) return -1;
    if (!ReadFile(s->h, buf, (DWORD)n, &got, NULL)) return -1;
    return (int)got;
}

/* ================================================================== the download */

typedef struct {
    HMODULE dll;
    HINTERNET (WINAPI *open)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
    HINTERNET (WINAPI *connect)(HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
    HINTERNET (WINAPI *openreq)(HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
    BOOL (WINAPI *send)(HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
    BOOL (WINAPI *recv)(HINTERNET, LPVOID);
    BOOL (WINAPI *query)(HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
    BOOL (WINAPI *readdata)(HINTERNET, LPVOID, DWORD, LPDWORD);
    BOOL (WINAPI *close)(HINTERNET);
    BOOL (WINAPI *timeouts)(HINTERNET, int, int, int, int);
    BOOL (WINAPI *setopt)(HINTERNET, DWORD, LPVOID, DWORD);
} wh_api;

static int wh_load(wh_api *a)
{
    memset(a, 0, sizeof *a);
    a->dll = LoadLibraryA("winhttp.dll");
    if (!a->dll) return 0;
#define GP(m, n) *(FARPROC *)&a->m = GetProcAddress(a->dll, n)
    GP(open, "WinHttpOpen"); GP(connect, "WinHttpConnect"); GP(openreq, "WinHttpOpenRequest"); GP(send, "WinHttpSendRequest");
    GP(recv, "WinHttpReceiveResponse"); GP(query, "WinHttpQueryHeaders"); GP(readdata, "WinHttpReadData"); GP(close, "WinHttpCloseHandle");
    GP(timeouts, "WinHttpSetTimeouts"); GP(setopt, "WinHttpSetOption");
#undef GP
    return a->open && a->connect && a->openreq && a->send && a->recv && a->query && a->readdata && a->close && a->setopt;
}

static const char *winhttp_error(DWORD e)
{
    switch (e) {
    case 12002: return "(the request timed out)";
    case 12007: return "(the server name could not be resolved)";
    case 12029: return "(cannot connect to the server)";
    case 12030: return "(the connection was dropped)";
    case 12037: case 12038: return "(the server's certificate is not valid for this name)";
    case 12044: return "(the server asked for a client certificate)";
    case 12045: return "(the server's certificate has an unknown issuer)";
    case 12157: return "(secure channel error)";
    case 12175: return "(the secure connection failed: certificate or date/time problem)";
    case 12152: return "(the server's answer was not understood)";
    default: return "";
    }
}

/* Downloads rt->url to `part`, following redirects by hand within the allowed hosts, into the file and the running SHA-256.
 * Returns 0 on success (exactly rt->size bytes), else a negative number after having said why. */
static int download(const rt_runtime *rt, const char *part, rt_sha256 *sha)
{
    wh_api wh;
    rt_url url;
    HINTERNET ses = NULL;
    HANDLE out = INVALID_HANDLE_VALUE;
    int hops, rc = -1;
    u64 got = 0;
    char sz_a[32], sz_b[32];

    if (!rt_url_parse(rt->url, &url) || !rt_host_allowed(url.host, rt->hosts)) { say("internal error: the address in the table is not allowed"); return -1; }
    if (!wh_load(&wh)) { say("winhttp.dll could not be loaded: this Windows has no networking"); return -1; }
    ses = wh.open(L"BCD-runtimes/1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (!ses) { say("WinHttpOpen failed, error %lu", (unsigned long)GetLastError()); return -1; }
    if (wh.timeouts) wh.timeouts(ses, 15000, 15000, 30000, 60000);
    {
        DWORD never = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;                  /* redirects are followed here, host by host */
        wh.setopt(ses, WINHTTP_OPTION_REDIRECT_POLICY, &never, sizeof never);
    }
    for (hops = 0; hops < 6; hops++) {
        WCHAR whost[160], wpath[1100];
        HINTERNET con, req;
        DWORD status = 0, size = sizeof status, err = 0;
        int redirected = 0;

        MultiByteToWideChar(CP_UTF8, 0, url.host, -1, whost, 160);
        MultiByteToWideChar(CP_UTF8, 0, url.path, -1, wpath, 1100);
        say("%s: GET https://%s%s", rt->id, url.host, url.path);
        con = wh.connect(ses, whost, INTERNET_DEFAULT_HTTPS_PORT, 0);
        if (!con) { err = GetLastError(); say("%s: connecting to %s failed, error %lu %s", rt->id, url.host, (unsigned long)err, winhttp_error(err)); goto out; }
        req = wh.openreq(con, L"GET", wpath, NULL, NULL, NULL, WINHTTP_FLAG_SECURE);
        if (!req) { err = GetLastError(); wh.close(con); say("%s: the request could not be made, error %lu", rt->id, (unsigned long)err); goto out; }
        {
            DWORD never = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
            wh.setopt(req, WINHTTP_OPTION_REDIRECT_POLICY, &never, sizeof never);
        }
        if (!wh.send(req, NULL, 0, NULL, 0, 0, 0) || !wh.recv(req, NULL)) {
            err = GetLastError();
            say("%s: the download failed, error %lu %s", rt->id, (unsigned long)err, winhttp_error(err));
            wh.close(req); wh.close(con);
            goto out;
        }
        if (!wh.query(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &size, NULL)) status = 0;
        if (status >= 300 && status < 400) {
            WCHAR loc[1100];
            char loc8[1100];
            DWORD lsz = sizeof loc;
            rt_url next;
            const char *why = "";
            if (!wh.query(req, WINHTTP_QUERY_LOCATION, NULL, loc, &lsz, NULL)) loc[0] = 0;
            WideCharToMultiByte(CP_UTF8, 0, loc, -1, loc8, sizeof loc8, NULL, NULL);
            wh.close(req); wh.close(con);
            if (!rt_redirect(&url, loc8, rt->hosts, &next, &why)) { say("%s: the server redirected the download: %s. Nothing was kept.", rt->id, why); goto out; }
            url = next;
            redirected = 1;
        } else if (status != 200) {
            wh.close(req); wh.close(con);
            say("%s: the server answered %lu instead of the file. Nothing was kept.", rt->id, (unsigned long)status);
            goto out;
        } else {
            WCHAR clen[40] = { 0 };
            DWORD csz = sizeof clen;
            char buf[65536];
            DWORD n;
            int last_tenth = -1;
            u64 length = 0;

            if (wh.query(req, WINHTTP_QUERY_CONTENT_LENGTH, NULL, clen, &csz, NULL)) length = _wcstoui64(clen, NULL, 10);
            if (length && length != rt->size) {
                rt_size_text(length, sz_a, sizeof sz_a);
                rt_size_text(rt->size, sz_b, sizeof sz_b);
                wh.close(req); wh.close(con);
                say("%s: the server says the file is %s (%llu bytes); the file BCD knows is %s (%llu bytes). Nothing was kept.", rt->id, sz_a,
                    (unsigned long long)length, sz_b, (unsigned long long)rt->size);
                goto out;
            }
            out = CreateFileA(part, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (out == INVALID_HANDLE_VALUE) {
                wh.close(req); wh.close(con);
                say("%s: cannot create %s, error %lu", rt->id, part, (unsigned long)GetLastError());
                goto out;
            }
            rt_sha256_init(sha);
            for (;;) {
                DWORD wrote = 0;
                if (InterlockedCompareExchange(&g_abort, 0, 0)) { wh.close(req); wh.close(con); say("%s: cancelled; the partial file is deleted", rt->id); goto out; }
                if (!wh.readdata(req, buf, sizeof buf, &n)) {
                    err = GetLastError();
                    wh.close(req); wh.close(con);
                    say("%s: the download broke off after %llu bytes, error %lu %s", rt->id, (unsigned long long)got, (unsigned long)err, winhttp_error(err));
                    goto out;
                }
                if (n == 0) break;
                if (got + n > rt->size) {
                    wh.close(req); wh.close(con);
                    say("%s: the server sent more than the %llu bytes of the file BCD knows. Nothing was kept.", rt->id, (unsigned long long)rt->size);
                    goto out;
                }
                if (!WriteFile(out, buf, n, &wrote, NULL) || wrote != n) {
                    wh.close(req); wh.close(con);
                    say("%s: writing the file failed, error %lu (is the disk full?)", rt->id, (unsigned long)GetLastError());
                    goto out;
                }
                rt_sha256_update(sha, buf, n);
                got += n;
                {
                    int tenth = rt_tenth(got, rt->size);
                    rt_size_text(got, sz_a, sizeof sz_a);
                    rt_size_text(rt->size, sz_b, sizeof sz_b);
                    set_status((int)(got * 100 / rt->size), "Downloading: %s of %s", sz_a, sz_b);
                    if (tenth != last_tenth) {
                        last_tenth = tenth;
                        say("%s: downloaded %s of %s (%d%%)", rt->id, sz_a, sz_b, tenth * 10);
                    }
                }
            }
            wh.close(req); wh.close(con);
            if (got != rt->size) {
                say("%s: the download ended after %llu of %llu bytes. Nothing was kept.", rt->id, (unsigned long long)got, (unsigned long long)rt->size);
                goto out;
            }
            rc = 0;
            goto out;
        }
        if (!redirected) goto out;
    }
    say("%s: too many redirects. Nothing was kept.", rt->id);
out:
    if (out != INVALID_HANDLE_VALUE) { if (rc == 0) FlushFileBuffers(out); CloseHandle(out); }
    if (rc != 0) DeleteFileA(part);
    if (ses) wh.close(ses);
    return rc;
}

/* The SHA-256 and size of a file on disk. Returns 0 and fills the digest, or -1. */
static int hash_file(const char *path, u8 digest[32], u64 *size_out)
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    static u8 buf[1 << 16];
    DWORD n;
    u64 total = 0;
    rt_sha256 s;

    if (h == INVALID_HANDLE_VALUE) return -1;
    rt_sha256_init(&s);
    while (ReadFile(h, buf, sizeof buf, &n, NULL) && n) {
        rt_sha256_update(&s, buf, n);
        total += n;
        if (InterlockedCompareExchange(&g_abort, 0, 0)) { CloseHandle(h); return -1; }
    }
    CloseHandle(h);
    rt_sha256_final(&s, digest);
    *size_out = total;
    return 0;
}

/* Gets the vendor's file onto the disk and checks it. On success `path` is a file whose size and SHA-256 are the pinned ones. */
static int fetch(const rt_runtime *rt, char *path, size_t cap, int *downloaded)
{
    char part[MAX_PATH], have[65];
    u8 digest[32];
    u64 size = 0;
    rt_sha256 sha;

    *downloaded = 0;
    memset(digest, 0, sizeof digest);
    if (g_local_file[0]) {
        say("%s: using the file you gave: %s", rt->id, g_local_file);
        snprintf(path, cap, "%s", g_local_file);
    } else {
        snprintf(path, cap, "%s\\%s", RT_DIR, rt->file);
        snprintf(part, sizeof part, "%s.part", path);
        if (file_exists(path)) {
            set_status(-1, "Checking the file from an earlier run");
            if (hash_file(path, digest, &size) == 0 && size == rt->size && rt_sha256_is(digest, rt->sha256)) {
                say("%s: the file from an earlier run is complete and its SHA-256 is right; no download needed", rt->id);
                return 0;
            }
            say("%s: the file from an earlier run is not the right one; it is deleted", rt->id);
            DeleteFileA(path);
        }
        set_status(0, "Downloading");
        if (download(rt, part, &sha) != 0) return -1;
        *downloaded = 1;
        rt_sha256_final(&sha, digest);
        rt_hex(digest, 32, have);
        if (!rt_sha256_is(digest, rt->sha256)) {
            say("%s: the SHA-256 of the download is %s, not the %s BCD was made for. Vendors replace files now and then; BCD needs an update. The file is deleted and nothing was run.",
                rt->id, have, rt->sha256);
            DeleteFileA(part);
            return -1;
        }
        if (!MoveFileExA(part, path, MOVEFILE_REPLACE_EXISTING)) {
            say("%s: the downloaded file could not be renamed, error %lu", rt->id, (unsigned long)GetLastError());
            DeleteFileA(part);
            return -1;
        }
        say("%s: SHA-256 checked: %s", rt->id, have);
        return 0;
    }
    set_status(-1, "Checking the file");
    if (hash_file(path, digest, &size) != 0 || size != rt->size || !rt_sha256_is(digest, rt->sha256)) {
        rt_hex(digest, 32, have);
        say("%s: that file is not the one BCD knows (size %llu, SHA-256 %s). Nothing was run.", rt->id, (unsigned long long)size, have);
        return -1;
    }
    say("%s: SHA-256 and size are right", rt->id);
    return 0;
}

/* ================================================================== running programs */

/* Runs a program and waits for it. `log_to` (may be NULL) is a file that gets its output. Returns 0 and the exit code, or -1 when it
 * could not be started (after saying why). The wait lasts at most `limit_s`; the program is not killed then. */
static int run_wait(const char *label, const char *exe, const char *args, const char *cwd, const char *log_to, unsigned limit_s, DWORD *code)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char cmd[2048];
    DWORD wait = 0;
    unsigned waited = 0;
    HANDLE log = INVALID_HANDLE_VALUE;
    SECURITY_ATTRIBUTES sa;

    snprintf(cmd, sizeof cmd, "\"%s\" %s", exe, args);
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    memset(&pi, 0, sizeof pi);
    if (log_to) {
        sa.nLength = sizeof sa; sa.lpSecurityDescriptor = NULL; sa.bInheritHandle = TRUE;
        log = CreateFileA(log_to, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (log != INVALID_HANDLE_VALUE) {
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdOutput = log;
            si.hStdError = log;
            si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        }
    }
    say("%s: starting %s", label, cmd);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, log != INVALID_HANDLE_VALUE, 0, NULL, cwd, &si, &pi)) {
        say("%s: %s could not be started, error %lu", label, exe, (unsigned long)GetLastError());
        if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
        return -1;
    }
    for (;;) {
        wait = WaitForSingleObject(pi.hProcess, 1000);
        if (wait != WAIT_TIMEOUT) break;
        waited++;
        set_status(-1, "%s is running (%u s)", label, waited);
        if (waited % 30 == 0) say("%s: still running after %u s", label, waited);
        if (waited >= limit_s) break;
    }
    if (wait == WAIT_OBJECT_0) {
        GetExitCodeProcess(pi.hProcess, code);
        say("%s: finished with exit code %lu after %u s", label, (unsigned long)*code, waited);
    } else {
        *code = 0xFFFFFFFFu;
        say("%s: still running after %u s; not waiting any longer (it is not stopped)", label, waited);
    }
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
    return wait == WAIT_OBJECT_0 ? 0 : -2;
}

/* The last lines of a text file, said into the log (for a program whose output went to a file). */
static void say_tail(const char *label, const char *path, int lines)
{
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    static char buf[6000];
    DWORD n = 0;
    LARGE_INTEGER size;
    char *p, *start;
    int count = 0;

    if (h == INVALID_HANDLE_VALUE) return;
    if (GetFileSizeEx(h, &size) && size.QuadPart > (LONGLONG)sizeof buf - 1) { LARGE_INTEGER pos; pos.QuadPart = size.QuadPart - (LONGLONG)(sizeof buf - 1); SetFilePointerEx(h, pos, NULL, FILE_BEGIN); }
    ReadFile(h, buf, sizeof buf - 1, &n, NULL);
    CloseHandle(h);
    buf[n] = 0;
    for (p = buf; *p; p++) if ((unsigned char)*p < 9 || ((unsigned char)*p > 13 && (unsigned char)*p < 32)) *p = ' ';
    start = buf + n;
    while (start > buf && count < lines) { start--; if (*start == '\n' && ++count > lines) { start++; break; } }
    for (p = start; *p;) {
        char *eol = strchr(p, '\n');
        char line[300];
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        if (len && p[len - 1] == '\r') len--;
        if (len >= sizeof line) len = sizeof line - 1;
        memcpy(line, p, len);
        line[len] = 0;
        if (line[0]) say("%s: > %s", label, line);
        if (!eol) break;
        p = eol + 1;
    }
}

/* ================================================================== the marker file */

static void marker_path(const rt_runtime *rt, char *out, size_t cap) { snprintf(out, cap, "%s\\%s.txt", RT_DIR, rt->id); }

static void write_marker(const rt_runtime *rt, const char *verdict, const char *extra_lines)
{
    char path[MAX_PATH], text[12000];
    SYSTEMTIME t;
    HANDLE h;
    DWORD done;
    int n;

    marker_path(rt, path, sizeof path);
    GetSystemTime(&t);
    n = snprintf(text, sizeof text, "runtime=%s\r\ntitle=%s\r\nvendor=%s\r\nsource=%s\r\nsha256=%s\r\ninstalled=%04d-%02d-%02d %02d:%02d:%02d UTC\r\nverdict=%s\r\n%s",
                 rt->id, rt->title, rt->vendor, rt->url, rt->sha256, t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, verdict, extra_lines ? extra_lines : "");
    if (n >= (int)sizeof text) n = (int)sizeof text - 1;                   /* snprintf says how long it would have been */
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        if (n > 0) WriteFile(h, text, (DWORD)n, &done, NULL);
        CloseHandle(h);
    }
}

/* ================================================================== what is installed */

/* The DirectX runtime has no fixed file list: its marker names the files it added. Returns how many of them are there and how many it lists. */
static int dx_marker_files(int *listed)
{
    char path[MAX_PATH];
    HANDLE h;
    static char text[24000];
    DWORD n = 0;
    char *p;
    int have = 0;

    *listed = 0;
    marker_path(rt_find("dx2010"), path, sizeof path);
    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    ReadFile(h, text, sizeof text - 1, &n, NULL);
    CloseHandle(h);
    text[n] = 0;
    for (p = text; (p = strstr(p, "file=")) != NULL;) {
        char name[MAX_PATH];
        size_t len;
        p += 5;
        len = strcspn(p, "\r\n");
        if (len >= sizeof name) len = sizeof name - 1;
        memcpy(name, p, len);
        name[len] = 0;
        (*listed)++;
        if (file_exists(name)) have++;
        p += len;
    }
    return have;
}

/* 1 = installed (all its files are there), 2 = partly, 0 = not. */
static int installed_state(const rt_runtime *rt, int *have, int *total)
{
    if (rt->kind == RT_KIND_DX2010) {
        char path[MAX_PATH];
        marker_path(rt, path, sizeof path);
        *have = dx_marker_files(total);
        if (!file_exists(path)) return 0;
        if (*total == 0) return 1;                      /* a run that had nothing to add (every name was there already) is done all the same */
        return *have == *total ? 1 : *have > 0 ? 2 : 0;
    }
    *have = rt_check_count(&g_fs, rt, total);
    return *total > 0 && *have == *total ? 1 : *have > 0 ? 2 : 0;
}

/* ================================================================== the installs */

static int g_is64 = 1;

static int ph_mkdirs(void *ctx, const char *dir) { (void)ctx; return make_dirs(dir); }
static int ph_move(void *ctx, const char *src, const char *dst)
{
    (void)ctx;
    return MoveFileExA(src, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED) ? 0 : -1;
}
static int ph_reg_set(void *ctx, const px_reg *r)
{
    HKEY k;
    REGSAM view = r->view == 32 ? KEY_WOW64_32KEY : KEY_WOW64_64KEY;
    LONG e;
    (void)ctx;
    e = RegCreateKeyExA(HKEY_LOCAL_MACHINE, r->key, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE | view, NULL, &k, NULL);
    if (e != ERROR_SUCCESS) return -1;
    if (r->name) {
        if (r->type == PX_DWORD) {
            DWORD d = r->dword;
            e = RegSetValueExA(k, r->name[0] ? r->name : NULL, 0, REG_DWORD, (const BYTE *)&d, sizeof d);
        } else if (r->type == PX_MULTI) {
            char multi[700];
            size_t n = strlen(r->sz);
            memcpy(multi, r->sz, n);
            multi[n] = 0;
            multi[n + 1] = 0;
            e = RegSetValueExA(k, r->name, 0, REG_MULTI_SZ, (const BYTE *)multi, (DWORD)(n + 2));
        } else {
            e = RegSetValueExA(k, r->name[0] ? r->name : NULL, 0, REG_SZ, (const BYTE *)r->sz, (DWORD)strlen(r->sz) + 1);
        }
    }
    RegCloseKey(k);
    return e == ERROR_SUCCESS ? 0 : -1;
}
static int ph_reg_get(void *ctx, int view, const char *key, const char *name, unsigned *value)
{
    HKEY k;
    DWORD d = 0, size = sizeof d, type = 0;
    LONG e;
    (void)ctx;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, key, 0, KEY_QUERY_VALUE | (view == 32 ? KEY_WOW64_32KEY : KEY_WOW64_64KEY), &k) != ERROR_SUCCESS) return 1;
    e = RegQueryValueExA(k, name, NULL, &type, (LPBYTE)&d, &size);
    RegCloseKey(k);
    if (e != ERROR_SUCCESS || type != REG_DWORD) return 1;
    *value = d;
    return 0;
}
/* The system PATH (HKLM\System\CurrentControlSet\Control\Session Manager\Environment, Path): appended to when the folder is not in it. */
static int ph_path_add(void *ctx, const char *dir)
{
    HKEY k;
    char cur[8192];
    DWORD size = sizeof cur - 1, type = REG_EXPAND_SZ;
    LONG e;
    size_t dl = strlen(dir);
    const char *p;
    (void)ctx;
    if (RegCreateKeyExA(HKEY_LOCAL_MACHINE, "System\\CurrentControlSet\\Control\\Session Manager\\Environment", 0, NULL, 0,
                        KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &k, NULL) != ERROR_SUCCESS) return -1;
    e = RegQueryValueExA(k, "Path", NULL, &type, (LPBYTE)cur, &size);
    if (e != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) { cur[0] = 0; type = REG_EXPAND_SZ; }
    cur[sizeof cur - 1] = 0;
    for (p = cur; *p;) {
        size_t n = strcspn(p, ";");
        if (n == dl && _strnicmp(p, dir, n) == 0) { RegCloseKey(k); return 1; }
        p += n;
        if (*p == ';') p++;
    }
    if (strlen(cur) + dl + 2 >= sizeof cur) { RegCloseKey(k); return -1; }
    if (cur[0] && cur[strlen(cur) - 1] != ';') strcat(cur, ";");
    strcat(cur, dir);
    e = RegSetValueExA(k, "Path", 0, type, (const BYTE *)cur, (DWORD)strlen(cur) + 1);
    RegCloseKey(k);
    return e == ERROR_SUCCESS ? 0 : -1;
}

static int install_physx(const rt_runtime *rt, const char *installer, char *detail, size_t cap)
{
    char tmp[MAX_PATH], files[MAX_PATH], args[1400], logf[MAX_PATH];
    DWORD code = 0;
    px_host h;
    px_result r;
    int rc;

    if (!file_exists(SEVENZIP)) {
        say("%s: BCD's 7-Zip (%s) is not in this build, and the PhysX package needs it to be unpacked", rt->id, SEVENZIP);
        snprintf(detail, cap, "needs 7z.exe, which this build does not have");
        return RT_FAIL;
    }
    snprintf(tmp, sizeof tmp, "%s\\physx-tmp", RT_DIR);
    snprintf(logf, sizeof logf, "%s\\physx-7z.txt", RT_DIR);
    remove_tree(tmp);
    make_dirs(tmp);
    set_status(-1, "Unpacking NVIDIA's package with 7-Zip");
    snprintf(args, sizeof args, "x -y -bd -aoa \"-o%s\" \"%s\"", tmp, installer);
    rc = run_wait("7-Zip", SEVENZIP, args, tmp, logf, 900, &code);
    snprintf(files, sizeof files, "%s\\PhysX\\files", tmp);
    if (rc != 0 || code != 0 || !file_exists(files)) {
        say_tail("7-Zip", logf, 8);
        remove_tree(tmp);
        snprintf(detail, cap, "the package could not be unpacked (7-Zip exit code %lu)", (unsigned long)code);
        return RT_FAIL;
    }
    h.exists = win_exists; h.mkdirs = ph_mkdirs; h.move_replace = ph_move; h.reg_set = ph_reg_set; h.reg_get_dword = ph_reg_get;
    h.path_add = ph_path_add; h.say = say_ctx; h.ctx = NULL;
    set_status(-1, "Putting PhysX in place");
    r = px_install(&h, files, g_is64, 1);
    remove_tree(tmp);
    if (r.newer) {
        snprintf(detail, cap, "a newer PhysX is installed already; nothing was changed");
        return RT_SKIP;
    }
    g_failed_count += r.failed;
    snprintf(detail, cap, "%d files copied to %s, %d registry values written, Common added to PATH", r.copied, PX_LOC, r.registry);
    return r.failed ? (r.copied ? RT_WARN : RT_FAIL) : RT_PASS;
}

static int install_msi(const rt_runtime *rt, const char *installer, char *detail, size_t cap)
{
    char args[1400], logf[MAX_PATH];
    const char *msiexec = file_exists(SYS_DIR64 "\\msiexec.exe") ? SYS_DIR64 "\\msiexec.exe" : SYS_DIR32 "\\msiexec.exe";
    DWORD code = 0;
    int rc;

    if (!file_exists(msiexec)) {
        say("%s: msiexec.exe is not in this Windows (system32 or syswow64)", rt->id);
        snprintf(detail, cap, "msiexec.exe is missing");
        return RT_FAIL;
    }
    snprintf(logf, sizeof logf, "%s\\%s-msi.txt", RT_DIR, rt->id);
    snprintf(args, sizeof args, "/i \"%s\" /qn /norestart /l*v \"%s\"", installer, logf);
    set_status(-1, "Windows Installer is running");
    say("%s: Windows Installer (msiexec) installs the package; its own log is %s", rt->id, logf);
    rc = run_wait("msiexec", msiexec, args, RT_DIR, NULL, 1500, &code);
    if (rc == -1) { snprintf(detail, cap, "msiexec could not be started"); return RT_FAIL; }
    if (rc == -2) { snprintf(detail, cap, "msiexec was still running after 25 minutes"); return RT_WARN; }
    if (!rt_msi_exit_ok(code)) {
        say_tail("msiexec", logf, 10);
        snprintf(detail, cap, "msiexec ended with code %lu", (unsigned long)code);
        return RT_FAIL;
    }
    snprintf(detail, cap, "msiexec finished with code %lu", (unsigned long)code);
    return RT_PASS;
}

static int install_openal(const rt_runtime *rt, const char *installer, char *detail, size_t cap)
{
    HANDLE h = CreateFileA(installer, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    LARGE_INTEGER size;
    u8 *zip = NULL, *exe = NULL;
    DWORD got = 0;
    rt_zip_entry e;
    char dir[MAX_PATH], path[MAX_PATH];
    HANDLE out;
    DWORD wrote = 0, code = 0;
    int r, rc = RT_FAIL;

    if (h == INVALID_HANDLE_VALUE || !GetFileSizeEx(h, &size) || size.QuadPart > (64 << 20)) { snprintf(detail, cap, "the ZIP file cannot be read"); if (h != INVALID_HANDLE_VALUE) CloseHandle(h); return RT_FAIL; }
    zip = (u8 *)malloc((size_t)size.QuadPart + 1);
    if (!zip || !ReadFile(h, zip, (DWORD)size.QuadPart, &got, NULL) || got != size.QuadPart) { CloseHandle(h); free(zip); snprintf(detail, cap, "the ZIP file cannot be read"); return RT_FAIL; }
    CloseHandle(h);
    r = rt_zip_find(zip, (size_t)size.QuadPart, "oalinst.exe", &e);
    if (r != 0 || e.usize == 0 || e.usize > (32u << 20)) {
        say("%s: oalinst.zip does not hold oalinst.exe as expected (code %d)", rt->id, r);
        free(zip);
        snprintf(detail, cap, "oalinst.zip is not what was expected");
        return RT_FAIL;
    }
    exe = (u8 *)malloc((size_t)e.usize + 1);
    r = exe ? rt_zip_extract(zip, (size_t)size.QuadPart, &e, exe) : -9;
    free(zip);
    if (r != 0) { say("%s: oalinst.exe could not be unpacked from the ZIP (code %d)", rt->id, r); free(exe); snprintf(detail, cap, "unpacking failed"); return RT_FAIL; }
    snprintf(dir, sizeof dir, "%s\\openal-tmp", RT_DIR);
    remove_tree(dir);
    make_dirs(dir);
    snprintf(path, sizeof path, "%s\\oalinst.exe", dir);
    out = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (out == INVALID_HANDLE_VALUE || !WriteFile(out, exe, (DWORD)e.usize, &wrote, NULL) || wrote != e.usize) {
        if (out != INVALID_HANDLE_VALUE) CloseHandle(out);
        free(exe);
        snprintf(detail, cap, "oalinst.exe could not be written");
        return RT_FAIL;
    }
    CloseHandle(out);
    free(exe);
    say("%s: oalinst.exe (%llu bytes, CRC-32 checked) unpacked from the ZIP", rt->id, (unsigned long long)e.usize);
    set_status(-1, "OpenAL installer is running");
    r = run_wait("oalinst", path, "/s", dir, NULL, 600, &code);
    remove_tree(dir);
    if (r == -1) { snprintf(detail, cap, "oalinst.exe could not be started"); return RT_FAIL; }
    if (r == -2) { snprintf(detail, cap, "oalinst.exe was still running after 10 minutes"); return RT_WARN; }
    snprintf(detail, cap, "oalinst.exe finished with code %lu", (unsigned long)code);
    rc = RT_PASS;
    return rc;
}

static int install_dx(const rt_runtime *rt, const char *installer, char *detail, size_t cap)
{
    HMODULE cab = LoadLibraryA("cabinet.dll");
    rt_fdi_api api;
    win_src ws;
    rt_src src;
    rt_dx *dx = (rt_dx *)calloc(1, sizeof *dx);
    static u8 head[1 << 20];
    DWORD got = 0;
    LARGE_INTEGER fsize;
    long long at;
    u64 cab_size = 0;
    int rc, i, verdict;
    char marker[8000];
    size_t mlen = 0;

    memset(&ws, 0, sizeof ws);
    if (!cab) { say("%s: cabinet.dll could not be loaded", rt->id); free(dx); snprintf(detail, cap, "cabinet.dll is missing"); return RT_FAIL; }
    *(FARPROC *)&api.create = GetProcAddress(cab, "FDICreate");
    *(FARPROC *)&api.copy = GetProcAddress(cab, "FDICopy");
    *(FARPROC *)&api.destroy = GetProcAddress(cab, "FDIDestroy");
    if (!api.create || !api.copy || !api.destroy || !dx) { say("%s: cabinet.dll has no FDI functions", rt->id); free(dx); snprintf(detail, cap, "cabinet.dll has no FDI"); return RT_FAIL; }
    ws.h = CreateFileA(installer, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_FLAG_RANDOM_ACCESS, NULL);
    if (ws.h == INVALID_HANDLE_VALUE || !GetFileSizeEx(ws.h, &fsize)) { say("%s: the file cannot be opened", rt->id); free(dx); snprintf(detail, cap, "the file cannot be opened"); return RT_FAIL; }
    if (!ReadFile(ws.h, head, sizeof head, &got, NULL)) got = 0;
    at = rt_find_cab(head, got, (u64)fsize.QuadPart, &cab_size);
    if (at < 0) {
        say("%s: no cabinet found in the first megabyte of the file", rt->id);
        CloseHandle(ws.h);
        free(dx);
        snprintf(detail, cap, "no cabinet in the file");
        return RT_FAIL;
    }
    say("%s: the cabinet starts at byte %lld (%llu bytes)", rt->id, at, (unsigned long long)cab_size);
    src.read = ws_read; src.ctx = &ws; src.base = (u64)at; src.length = cab_size;
    dx->api = &api;
    dx->src = &src;
    dx->dest.exists = win_exists; dx->dest.begin = wd_begin; dx->dest.write = wd_write; dx->dest.commit = wd_commit; dx->dest.abort = wd_abort;
    dx->dir_x86 = SYS_DIR32;
    dx->dir_x64 = SYS_DIR64;
    dx->say = say_ctx;
    make_dirs(SYS_DIR32);
    set_status(-1, "Reading the DirectX cabinets");
    say("%s: reading the cabinets; a DLL is written only where nothing of its name is there yet", rt->id);
    rc = rt_dx_extract(dx);
    CloseHandle(ws.h);
    for (i = 0; i < dx->st.list_n; i++)
        say("%s: added %s\\%s", rt->id, dx->st.list[i].is64 ? SYS_DIR64 : SYS_DIR32, dx->st.list[i].name);
    say("%s: %d cabinets read, %d DLLs added, %d already there and kept as they are, %d files skipped (setup, catalogs, .inf), %d other cabinets skipped",
        rt->id, dx->st.cabs_read, dx->st.added, dx->st.kept, dx->st.skipped_files, dx->st.cabs_skipped);
    for (i = 0; i < dx->st.list_n && mlen + 200 < sizeof marker; i++)
        mlen += (size_t)snprintf(marker + mlen, sizeof marker - mlen, "file=%s\\%s\r\n", dx->st.list[i].is64 ? SYS_DIR64 : SYS_DIR32, dx->st.list[i].name);
    marker[mlen] = 0;
    g_failed_count += dx->st.failed;
    snprintf(detail, cap, "%d DLLs added (%d already provided by BCD or an earlier run, kept)", dx->st.added, dx->st.kept);
    verdict = rc != 0 ? RT_FAIL : dx->st.failed ? (dx->st.added ? RT_WARN : RT_FAIL) : RT_PASS;
    if (verdict != RT_FAIL) write_marker(rt, rt_verdict_name(verdict), marker);      /* the marker means "this was done" */
    free(dx);
    return verdict;
}

/* ================================================================== one run */

static void finish(const rt_runtime *rt, int verdict, const char *detail)
{
    char line[600];
    rt_result_line(line, sizeof line, rt->id, verdict, g_failed_count, detail);
    emit(line);
    if (verdict == RT_PASS) set_status(100, "Done: %s", detail);
    else set_status(g_percent < 0 ? 0 : g_percent, "%s: %s", rt_verdict_name(verdict), detail);
}

static void run_install(const rt_runtime *rt)
{
    char path[MAX_PATH], detail[400], size_text[40], line[400];
    ULARGE_INTEGER avail, total, freeb;
    int downloaded = 0, verdict;
    int have, count, state;

    g_failed_count = 0;
    CreateDirectoryA(BASE_DIR, NULL);
    make_dirs(RT_DIR);
    rt_size_text(rt->size, size_text, sizeof size_text);
    say("%s: %s", rt->id, rt->title);
    say("%s: from %s, %s, about %u MB of free space needed", rt->id, rt->vendor, size_text, rt->need_mb);
    if (GetDiskFreeSpaceExA(BASE_DIR, &avail, &total, &freeb) && avail.QuadPart < (ULONGLONG)rt->need_mb << 20) {
        snprintf(line, sizeof line, "not enough free space: %llu MB free, %u MB needed", (unsigned long long)(avail.QuadPart >> 20), rt->need_mb);
        say("%s: %s", rt->id, line);
        fail_count();
        finish(rt, RT_FAIL, line);
        return;
    }
    state = installed_state(rt, &have, &count);
    if (state == 1) say("%s: it is installed already; this run installs it again", rt->id);
    if (fetch(rt, path, sizeof path, &downloaded) != 0) {
        fail_count();
        finish(rt, RT_FAIL, g_abort ? "cancelled" : "the vendor's file could not be fetched or did not match; nothing was installed");
        return;
    }
    switch (rt->kind) {
    case RT_KIND_MSI: verdict = install_msi(rt, path, detail, sizeof detail); break;
    case RT_KIND_PHYSX: verdict = install_physx(rt, path, detail, sizeof detail); break;
    case RT_KIND_ZIP_EXE: verdict = install_openal(rt, path, detail, sizeof detail); break;
    default: verdict = install_dx(rt, path, detail, sizeof detail); break;
    }
    if (verdict == RT_FAIL || verdict == RT_WARN) fail_count();
    if (rt->kind != RT_KIND_DX2010 && (verdict == RT_PASS || verdict == RT_WARN)) {
        /* the vendor's installer says it is done: look for what it should have left (a few seconds' patience for a service that finishes late) */
        int tries;
        for (tries = 0; tries < 15; tries++) {
            state = installed_state(rt, &have, &count);
            if (state == 1) break;
            Sleep(2000);
        }
        if (state == 1) {
            say("%s: verified: all %d expected files are there", rt->id, count);
        } else if (verdict == RT_PASS) {
            say("%s: the installer finished, but only %d of %d expected files are there", rt->id, have, count);
            verdict = have ? RT_WARN : RT_FAIL;
            fail_count();
        }
        if (verdict == RT_PASS || verdict == RT_WARN) {
            char extra[200];
            snprintf(extra, sizeof extra, "files_found=%d of %d\r\n", have, count);
            write_marker(rt, rt_verdict_name(verdict), extra);
        }
        {
            char tail[300];
            snprintf(tail, sizeof tail, "%s; %d of %d expected files found", detail, have, count);
            snprintf(detail, sizeof detail, "%s", tail);
        }
    }
    if (!g_keep && !g_local_file[0] && (verdict == RT_PASS || verdict == RT_WARN || verdict == RT_SKIP)) {
        DeleteFileA(path);
        say("%s: the downloaded file is deleted (--keep keeps it)", rt->id);
    }
    finish(rt, verdict, detail);
}

/* C:\ProgramData\BCD\Runtimes\status.txt: one "<id>=installed|partly|missing" line for each runtime, for whatever wants to know without
 * running this window (the app's launch check reads the same files this looks for: rt_check_xna and the others in core.h). */
static void write_status_file(void)
{
    char path[MAX_PATH], text[600];
    size_t i, n = 0;
    HANDLE h;
    DWORD done;

    make_dirs(RT_DIR);
    snprintf(path, sizeof path, "%s\\status.txt", RT_DIR);
    for (i = 0; i < RT_COUNT && n + 60 < sizeof text; i++) {
        int have = 0, total = 0, s = installed_state(&rt_table[i], &have, &total);
        n += (size_t)snprintf(text + n, sizeof text - n, "%s=%s\r\n", rt_table[i].id, s == 1 ? "installed" : s == 2 ? "partly" : "missing");
    }
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        WriteFile(h, text, (DWORD)n, &done, NULL);
        CloseHandle(h);
    }
}

static void run_status(void)
{
    size_t i;
    char line[500], detail[500] = "";
    int n_installed = 0;

    g_failed_count = 0;
    say("Runtimes you can install from the Start menu (BCD Runtimes):");
    for (i = 0; i < RT_COUNT; i++) {
        const rt_runtime *rt = &rt_table[i];
        int have = 0, total = 0, s = installed_state(rt, &have, &total);
        char mp[MAX_PATH];
        marker_path(rt, mp, sizeof mp);
        snprintf(line, sizeof line, "  %-22s %s%s", rt->menu,
                 s == 1 ? "installed" : s == 2 ? "partly installed" : "not installed",
                 s ? (file_exists(mp) ? " (by BCD)" : " (not by BCD's installer)") : "");
        if (s == 2) snprintf(line + strlen(line), sizeof line - strlen(line), ": %d of %d files", have, total);
        emit(line);
        if (s == 1) n_installed++;
        snprintf(detail + strlen(detail), sizeof detail - strlen(detail), "%s%s=%s", i ? ", " : "", rt->id, s == 1 ? "yes" : s == 2 ? "partly" : "no");
    }
    emit("");
    emit("Media Foundation has no installer to run: BCD carries Wine's Media Foundation (mf, mfplat, mfreadwrite) with its own decoders,");
    emit("and Microsoft's Media Feature Pack belongs to Windows itself, not to a program one can install into Wine.");
    emit("Visual C++ and .NET: see \"VC++ and .NET check\" in BCD Tests; BCD's Settings downloads the Visual C++ runtime and Wine Mono.");
    emit("");
    emit("The downloads are kept in C:\\ProgramData\\BCD\\Runtimes (Files app > BCD > wine > drive_c > ProgramData) only until the install worked.");
    {
        char r[700];
        snprintf(r, sizeof r, "%d of %d installed (%s)", n_installed, (int)RT_COUNT, detail);
        rt_result_line(line, sizeof line, "status", RT_PASS, 0, r);
        emit(line);
    }
    write_status_file();
    set_status(100, "%d of %d installed", n_installed, (int)RT_COUNT);
}

/* ================================================================== the window */

static DWORD WINAPI worker_main(LPVOID arg)
{
    (void)arg;
    if (g_rt) run_install(g_rt);
    else run_status();
    InterlockedExchange(&g_busy, 0);
    if (g_wnd) PostMessageA(g_wnd, WM_DONE, 0, 0);
    return 0;
}

static void start_worker(void)
{
    if (InterlockedExchange(&g_busy, 1)) return;
    InterlockedExchange(&g_abort, 0);
    EnableWindow(g_go, FALSE);
    g_worker = CreateThread(NULL, 0, worker_main, NULL, 0, NULL);
    if (!g_worker) { InterlockedExchange(&g_busy, 0); EnableWindow(g_go, TRUE); emit("the work thread could not be started"); }
}

static void layout(int w, int h)
{
    int pad = 10, info_h = h * 33 / 100, btn_h = 26, bar_h = 14, y = pad;
    if (info_h < 90) info_h = 90;
    if (info_h > h - 150) info_h = h - 150;
    MoveWindow(g_info, pad, y, w - 2 * pad, info_h, TRUE);
    y += info_h + 4;
    MoveWindow(g_status, pad, y, w - 2 * pad, 16, TRUE);
    y += 20 + bar_h + 6;                                                        /* the bar is painted at y - bar_h - 6 */
    {
        int edit_h = h - y - btn_h - 2 * pad;
        MoveWindow(g_edit, pad, y, w - 2 * pad > 40 ? w - 2 * pad : 40, edit_h > 40 ? edit_h : 40, TRUE);
    }
    MoveWindow(g_go, w - pad - 2 * 150 - 8, h - pad - btn_h, 150, btn_h, TRUE);
    MoveWindow(g_close, w - pad - 150, h - pad - btn_h, 150, btn_h, TRUE);
}

static RECT bar_rect(HWND wnd)
{
    RECT c, r;
    int pad = 10, info_h;
    GetClientRect(wnd, &c);
    info_h = (c.bottom * 33 / 100);
    if (info_h < 90) info_h = 90;
    if (info_h > c.bottom - 150) info_h = c.bottom - 150;
    r.left = pad; r.right = c.right - pad;
    r.top = pad + info_h + 4 + 20; r.bottom = r.top + 14;
    return r;
}

static void paint_bar(HDC dc, HWND wnd)
{
    RECT r = bar_rect(wnd), fill;
    HBRUSH back = CreateSolidBrush(RGB(215, 215, 215)), front = CreateSolidBrush(RGB(30, 110, 200)), edge = CreateSolidBrush(RGB(120, 120, 120));
    LONG pct = g_percent;
    FillRect(dc, &r, back);
    fill = r;
    if (pct >= 0) {
        fill.right = r.left + (r.right - r.left) * (pct > 100 ? 100 : pct) / 100;
        FillRect(dc, &fill, front);
    } else if (g_busy) {
        int span = (r.right - r.left) / 4, off = (int)((GetTickCount() / 25) % (DWORD)(r.right - r.left - span));
        fill.left = r.left + off;
        fill.right = fill.left + span;
        FillRect(dc, &fill, front);
    }
    FrameRect(dc, &r, edge);
    DeleteObject(back); DeleteObject(front); DeleteObject(edge);
}

static LRESULT CALLBACK wndproc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    switch (m) {
    case WM_CREATE:
        g_info = CreateWindowExA(0, "STATIC", "", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_NOPREFIX, 0, 0, 10, 10, w, NULL, NULL, NULL);
        g_status = CreateWindowExA(0, "STATIC", "", WS_CHILD | WS_VISIBLE | SS_LEFT | SS_NOPREFIX, 0, 0, 10, 10, w, NULL, NULL, NULL);
        g_edit = CreateWindowExA(WS_EX_CLIENTEDGE, "EDIT", "", WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                 0, 0, 10, 10, w, (HMENU)(INT_PTR)3, NULL, NULL);
        g_go = CreateWindowExA(0, "BUTTON", g_rt ? "Download and install" : "Refresh", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 0, 0, 10, 10, w,
                               (HMENU)(INT_PTR)1, NULL, NULL);
        g_close = CreateWindowExA(0, "BUTTON", "Close", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 0, 0, 10, 10, w, (HMENU)(INT_PTR)2, NULL, NULL);
        g_font_ui = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
        g_font_mono = CreateFontA(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN, "Courier New");
        SendMessageA(g_info, WM_SETFONT, (WPARAM)g_font_ui, TRUE);
        SendMessageA(g_status, WM_SETFONT, (WPARAM)g_font_ui, TRUE);
        SendMessageA(g_edit, WM_SETFONT, (WPARAM)(g_font_mono ? g_font_mono : g_font_ui), TRUE);
        SendMessageA(g_go, WM_SETFONT, (WPARAM)g_font_ui, TRUE);
        SendMessageA(g_close, WM_SETFONT, (WPARAM)g_font_ui, TRUE);
        SetTimer(w, 1, 200, NULL);
        return 0;
    case WM_SIZE:
        layout(LOWORD(lp), HIWORD(lp));
        return 0;
    case WM_GETMINMAXINFO: {
        MINMAXINFO *mm = (MINMAXINFO *)lp;
        mm->ptMinTrackSize.x = 380;                  /* small enough for a small Wine desktop, large enough for the buttons and the plan */
        mm->ptMinTrackSize.y = 300;
        return 0;
    }
    case WM_TIMER:
        if (g_busy && g_percent < 0) InvalidateRect(w, NULL, FALSE);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(w, &ps);
        paint_bar(dc, w);
        EndPaint(w, &ps);
        return 0;
    }
    case WM_REFRESH: {
        char status[240];
        InterlockedExchange(&g_dirty, 0);
        EnterCriticalSection(&g_lock);
        if (g_text) SetWindowTextA(g_edit, g_text);
        snprintf(status, sizeof status, "%s", g_status_text);
        LeaveCriticalSection(&g_lock);
        SetWindowTextA(g_status, status);
        {
            int lines = (int)SendMessageA(g_edit, EM_GETLINECOUNT, 0, 0);
            SendMessageA(g_edit, EM_LINESCROLL, 0, lines);
        }
        {
            RECT r = bar_rect(w);
            InvalidateRect(w, &r, FALSE);
        }
        return 0;
    }
    case WM_DONE:
        EnableWindow(g_go, TRUE);
        SetWindowTextA(g_go, g_rt ? "Install again" : "Refresh");
        SetFocus(g_close);
        InvalidateRect(w, NULL, FALSE);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wp) == 1) start_worker();
        else if (LOWORD(wp) == 2) SendMessageA(w, WM_CLOSE, 0, 0);
        return 0;
    case WM_CLOSE:
        if (g_busy) {
            /* a download stops at once; an installer that is running is not interrupted: its window waits */
            InterlockedExchange(&g_abort, 1);
            if (g_worker && WaitForSingleObject(g_worker, 4000) != WAIT_OBJECT_0) {
                MessageBoxA(w, "An installer is still running. This window closes when it is done.", APP_TITLE, MB_OK | MB_ICONINFORMATION);
                return 0;
            }
        }
        DestroyWindow(w);
        return 0;
    case WM_DESTROY:
        KillTimer(w, 1);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(w, m, wp, lp);
}

static void build_info(char *out, size_t cap)
{
    char size_text[40];
    rt_url u;
    if (!g_rt) {
        snprintf(out, cap, "BCD runtimes\r\n\r\nWhich of the runtimes in this Start menu folder are installed. Each one is a separate entry that downloads and installs "
                           "only when you press its button.");
        return;
    }
    rt_size_text(g_rt->size, size_text, sizeof size_text);
    if (!rt_url_parse(g_rt->url, &u)) strcpy(u.host, "?");
    snprintf(out, cap, "%s\r\n\r\n%s\r\n\r\nDownload: %s (%s) from %s, only from there. BCD checks the file against the SHA-256 it was made for before it runs anything. "
                       "About %u MB of free space is needed, and the download uses your internet connection (mobile data too, when Wi-Fi is off). Nothing of it is part of BCD. %s\r\n\r\n"
                       "Pressing the button means you accept %s's terms for this software: %s",
             g_rt->title, g_rt->what, g_rt->file, size_text, u.host, g_rt->need_mb, g_rt->undo, g_rt->vendor, g_rt->licence);
}

/* ================================================================== main */

static void parse_command_line(char *id_out, size_t cap)
{
    char *cl = GetCommandLineA(), *p = cl;
    char tok[MAX_PATH];
    int index = 0, want_file = 0;

    id_out[0] = 0;
    while (*p) {
        size_t n = 0;
        while (*p == ' ') p++;
        if (!*p) break;
        if (*p == '"') {
            p++;
            while (*p && *p != '"' && n + 1 < sizeof tok) tok[n++] = *p++;
            if (*p == '"') p++;
        } else {
            while (*p && *p != ' ' && n + 1 < sizeof tok) tok[n++] = *p++;
        }
        tok[n] = 0;
        if (index++ == 0) continue;
        if (want_file) { snprintf(g_local_file, sizeof g_local_file, "%s", tok); want_file = 0; }
        else if (!strcmp(tok, "--install")) g_auto = 1;
        else if (!strcmp(tok, "--keep")) g_keep = 1;
        else if (!strcmp(tok, "--file")) want_file = 1;
        else if (!id_out[0]) snprintf(id_out, cap, "%s", tok);
    }
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    WNDCLASSA wc;
    MSG msg;
    char id[40], title[200], info[2400], mutex[80];
    RECT work;
    int w = 600, h = 460;
    HANDLE once;
    (void)prev; (void)cmd;

    InitializeCriticalSection(&g_lock);
    parse_command_line(id, sizeof id);
    if (id[0] && strcmp(id, "status") != 0) {
        g_rt = rt_find(id);
        if (!g_rt) {
            char what[200];
            snprintf(what, sizeof what, "BCD runtimes: \"%s\" is not one of xna, physx, openal, dx2010, status.", id);
            MessageBoxA(NULL, what, APP_TITLE, MB_OK | MB_ICONERROR);
            return 2;
        }
    }
    snprintf(mutex, sizeof mutex, "Local\\BCD-runtimes-%s", g_rt ? g_rt->id : "status");
    once = CreateMutexA(NULL, FALSE, mutex);
    if (once && GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxA(NULL, "This runtime's window is open already.", APP_TITLE, MB_OK | MB_ICONINFORMATION);
        return 0;
    }
    make_dirs(BASE_DIR);
    g_logfile = CreateFileA(LOG_FILE, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    InterlockedExchange(&g_percent, -1);

    memset(&wc, 0, sizeof wc);
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = "BCDRuntimes";
    if (!RegisterClassA(&wc)) g_headless = 1;
    if (SystemParametersInfoA(SPI_GETWORKAREA, 0, &work, 0)) {
        int ww = work.right - work.left, wh = work.bottom - work.top;
        if (w > ww - 8) w = ww - 8;
        if (h > wh - 8) h = wh - 8;
        if (w < 320) w = 320;
        if (h < 300) h = 300;
    }
    snprintf(title, sizeof title, "%s - %s", APP_TITLE, g_rt ? g_rt->menu : "installed runtimes");
    if (!g_headless) {
        g_wnd = CreateWindowExA(0, "BCDRuntimes", title, WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT, w, h, NULL, NULL, inst, NULL);
        if (!g_wnd) g_headless = 1;
    }
    if (g_headless) {
        /* no window could be made: run the work and log it */
        if (g_rt) run_install(g_rt); else run_status();
        return g_failed_count ? 1 : 0;
    }
    ShowWindow(g_wnd, show);
    build_info(info, sizeof info);
    SetWindowTextA(g_info, info);
    {
        RECT c;
        GetClientRect(g_wnd, &c);
        layout(c.right, c.bottom);
    }
    if (!g_rt) { set_status(-1, "Reading what is installed"); start_worker(); }
    else {
        int have = 0, total = 0, s = installed_state(g_rt, &have, &total);
        set_status(0, "%s", s == 1 ? "Already installed. The button installs it again." : s == 2 ? "Partly installed." : "Not installed yet. Press the button to download and install.");
        if (g_auto) PostMessageA(g_wnd, WM_COMMAND, 1, 0);
    }
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        if (!IsDialogMessageA(g_wnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
    }
    if (g_worker) WaitForSingleObject(g_worker, 8000);
    if (g_logfile != INVALID_HANDLE_VALUE) CloseHandle(g_logfile);
    return 0;
}
