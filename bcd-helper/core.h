// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// core.h: the part of BCD's start helper (bcd-helper/helper.c, round 604) that needs no Windows. helper.c includes it for the program;
// tests/host/check-bcd-helper.py compiles it for the host (clang, ASan/UBSan) with a stand-in for the operating system and runs core_test.c.
//
// What the helper is for. A game's own file can ask for three things that a Windows program has to do from inside the session:
//   * a delay before the game starts           -> `bcd-helper-x64.exe wait <seconds>`, a plain sleep the start script calls;
//   * a second program that runs beside it     -> the script starts it; the supervisor closes it again when the game has ended;
//   * window rules (bring a window to the front after a while, minimise and restore it, make it opaque).
// `bcd-helper-x64.exe supervise <file>` runs the last two: it reads the small text file BCD wrote next to the start script, then looks every
// half second at the processes and the top-level windows. Its name holds "helper" on purpose: the session-end check of BCD does not count a
// program by that name as the game's own, so the supervisor never keeps a finished session alive.
//
// What it never does: start, patch, inject into or read the memory of any program; touch a window that is the protection of a game (an
// anti-cheat or DRM program's window or process, named in hr_is_protection: such a rule is refused when the file is read and such a window
// is skipped when the windows are looked at); close anything but the second program it was told about, by its file name, and only after
// the game's own processes have been gone for 5 seconds. The file is the player's own and holds at most 16 rules.

#ifndef BCD_HELPER_CORE_H
#define BCD_HELPER_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif

typedef uint64_t hr_u64;

#define HR_MAX_RULES 16
#define HR_MAX_TRACK 256
#define HR_MAX_PROCS 512
#define HR_MAX_WINS 256
#define HR_END_GRACE_MS 5000u        /* the game's processes gone this long: it has ended */
#define HR_NEVER_STARTED_S 180u      /* after the delay, this long without the game appearing: give up */

typedef enum { HR_NONE = 0, HR_RAISE = 1, HR_MINIMIZE_RESTORE = 2, HR_OPAQUE = 3 } hr_action;
typedef enum { HR_MATCH_TITLE = 1, HR_MATCH_CLASS = 2 } hr_match;

typedef struct {
    hr_action action;
    hr_match match;
    char text[128];
    unsigned delay_ms;
} hr_rule;

typedef struct {
    char game[260];       /* the game's folder, lower case, backslashes, no trailing one; "" when unknown */
    char program[128];    /* the game's main program, lower case ("foo.exe") */
    char second[128];     /* the second program's file name to close at the end, lower case; "" for none */
    int stop;
    unsigned wait_s;      /* the start delay the script waits for */
    char log[260];        /* a text file the supervisor appends a line to when it acts ("" for none) */
    hr_rule rules[HR_MAX_RULES];
    int nrules;
} hr_config;

/* ------------------------------------------------------------------ text helpers */

static char hr_lower(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c; }

static void hr_lower_copy(char *dst, size_t cap, const char *src)
{
    size_t i = 0;
    for (; src[i] && i + 1 < cap; i++) dst[i] = hr_lower(src[i]);
    dst[i] = 0;
}

/* Case-insensitive substring: does `hay` hold `needle`? An empty needle matches nothing. */
static int hr_contains(const char *hay, const char *needle)
{
    size_t n = strlen(needle), h = strlen(hay), i, j;
    if (!n || n > h) return 0;
    for (i = 0; i + n <= h; i++) {
        for (j = 0; j < n; j++) if (hr_lower(hay[i + j]) != hr_lower(needle[j])) break;
        if (j == n) return 1;
    }
    return 0;
}

/* Names of protection programs (anti-cheat, DRM): a rule that names one is refused, and a window or process that holds one is left alone. */
static int hr_is_protection(const char *text)
{
    static const char *const names[] = {
        "easyanticheat", "easy anti-cheat", "easy anticheat", "eac_launcher", "eosanticheat", "battleye", "beclient", "beservice",
        "vanguard", "vgc.exe", "vgk", "equ8", "xigncode", "nprotect", "gameguard", "punkbuster", "pnkbstr", "faceit", "denuvo",
        "anti-cheat", "anticheat", "anti cheat", "uwssvc", "cheat engine", "ricochet",
    };
    size_t i;
    for (i = 0; i < sizeof names / sizeof names[0]; i++) if (hr_contains(text, names[i])) return 1;
    return 0;
}

/* ------------------------------------------------------------------ the file */

static void hr_trim(char *s)
{
    size_t n = strlen(s), a = 0;
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n')) s[--n] = 0;
    while (s[a] == ' ' || s[a] == '\t') a++;
    if (a) memmove(s, s + a, strlen(s + a) + 1);
}

static int hr_program_name_ok(const char *name)
{
    size_t n = strlen(name), i;
    if (n < 5 || n > 100 || hr_lower(name[n - 4]) != '.' || hr_lower(name[n - 3]) != 'e' || hr_lower(name[n - 2]) != 'x' || hr_lower(name[n - 1]) != 'e') return 0;
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c < 0x20 || c == '\\' || c == '/' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') return 0;
    }
    return 1;
}

/* Reads the config text:
 *   game=C:\Games\Foo         program=foo.exe         second=tool.exe         stop=1         wait=5
 *   rule=raise|title|Final Fantasy|1000       (action: raise, minimize-restore, opaque; match: title or class; delay in ms)
 * Lines starting with # are comments. Returns 0 and fills `out`, or -1 with a message in err. */
static int hr_parse_config(const char *text, hr_config *out, char *err, size_t errlen)
{
    const char *p = text;
    memset(out, 0, sizeof *out);
    out->stop = 1;
    while (*p) {
        char line[512];
        size_t n = 0;
        char *eq;
        while (*p && *p != '\n' && n + 1 < sizeof line) line[n++] = *p++;
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
        line[n] = 0;
        hr_trim(line);
        if (!line[0] || line[0] == '#') continue;
        eq = strchr(line, '=');
        if (!eq) { snprintf(err, errlen, "a line has no '=': %.40s", line); return -1; }
        *eq = 0;
        {
            char *value = eq + 1;
            hr_trim(line);
            hr_trim(value);
            if (!strcmp(line, "game")) {
                size_t len;
                hr_lower_copy(out->game, sizeof out->game, value);
                for (len = 0; out->game[len]; len++) if (out->game[len] == '/') out->game[len] = '\\';
                while (len > 3 && out->game[len - 1] == '\\') out->game[--len] = 0;
            } else if (!strcmp(line, "program")) {
                if (!hr_program_name_ok(value)) { snprintf(err, errlen, "program is a file name ending in .exe"); return -1; }
                hr_lower_copy(out->program, sizeof out->program, value);
            } else if (!strcmp(line, "second")) {
                if (value[0] && !hr_program_name_ok(value)) { snprintf(err, errlen, "second is a file name ending in .exe"); return -1; }
                hr_lower_copy(out->second, sizeof out->second, value);
            } else if (!strcmp(line, "log")) {
                size_t len = strlen(value);
                if (len && (len >= sizeof out->log || len < 4 || value[1] != ':' || value[2] != '\\')) { snprintf(err, errlen, "log is a path on a drive, like C:\\bcd-games\\x.log"); return -1; }
                strcpy(out->log, value);
            } else if (!strcmp(line, "stop")) {
                out->stop = value[0] != '0';
            } else if (!strcmp(line, "wait")) {
                long v = strtol(value, NULL, 10);
                out->wait_s = (v < 0 || v > 300) ? 0u : (unsigned)v;
            } else if (!strcmp(line, "rule")) {
                char *a = value, *b, *c, *d;
                hr_rule *r;
                if (out->nrules >= HR_MAX_RULES) { snprintf(err, errlen, "at most %d rules", HR_MAX_RULES); return -1; }
                b = strchr(a, '|'); if (!b) { snprintf(err, errlen, "a rule is action|title or class|text|delay"); return -1; } *b++ = 0;
                c = strchr(b, '|'); if (!c) { snprintf(err, errlen, "a rule is action|title or class|text|delay"); return -1; } *c++ = 0;
                d = strrchr(c, '|'); if (!d) { snprintf(err, errlen, "a rule is action|title or class|text|delay"); return -1; } *d++ = 0;
                r = &out->rules[out->nrules];
                if (!strcmp(a, "raise")) r->action = HR_RAISE;
                else if (!strcmp(a, "minimize-restore")) r->action = HR_MINIMIZE_RESTORE;
                else if (!strcmp(a, "opaque")) r->action = HR_OPAQUE;
                else { snprintf(err, errlen, "an action is raise, minimize-restore or opaque"); return -1; }
                if (!strcmp(b, "title")) r->match = HR_MATCH_TITLE;
                else if (!strcmp(b, "class")) r->match = HR_MATCH_CLASS;
                else { snprintf(err, errlen, "a rule matches the title or the class"); return -1; }
                hr_trim(c);
                if (!c[0] || strlen(c) >= sizeof r->text) { snprintf(err, errlen, "the text of a rule is 1 to 127 characters"); return -1; }
                if (hr_is_protection(c)) { snprintf(err, errlen, "a rule never names an anti-cheat or protection program"); return -1; }
                strcpy(r->text, c);
                {
                    long ms = strtol(d, NULL, 10);
                    r->delay_ms = (ms < 0) ? 0u : (ms > 60000 ? 60000u : (unsigned)ms);
                }
                out->nrules++;
            } else {
                snprintf(err, errlen, "unknown key %.30s", line);
                return -1;
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ what the supervisor sees */

typedef struct { unsigned pid; char name[128]; char dir[260]; } hr_proc;          /* name and dir lower case */
typedef struct { hr_u64 handle; unsigned pid; char title[256]; char cls[128]; } hr_win;

typedef struct hr_os {
    void *user;
    unsigned (*now_ms)(void *);
    void (*sleep_ms)(void *, unsigned);
    int (*list_processes)(void *, hr_proc *out, int max);
    int (*list_windows)(void *, hr_win *out, int max);      /* visible top-level windows */
    void (*apply)(void *, hr_u64 handle, hr_action action);
    void (*terminate)(void *, unsigned pid);
    unsigned self_pid;
} hr_os;

typedef struct { int rule; hr_u64 handle; unsigned first_ms; int done; int alive; } hr_track;

typedef struct {
    unsigned start_ms;
    int started;
    int game_seen;
    int has_last;
    unsigned last_game_ms;
    hr_track track[HR_MAX_TRACK];
    int ntrack;
    int applied;      /* rule actions applied, for the log and the tests */
    int stopped;      /* processes closed */
} hr_state;

static void hr_init(hr_state *s, const hr_os *os)
{
    memset(s, 0, sizeof *s);
    s->start_ms = os->now_ms(os->user);
    s->started = 1;
}

static int hr_is_game_process(const hr_config *c, const hr_proc *p)
{
    size_t n;
    if (c->second[0] && !strcmp(p->name, c->second)) return 0;   /* the second program is not the game, wherever it lives */
    if (c->program[0] && !strcmp(p->name, c->program)) return 1;
    if (!c->game[0]) return 0;
    n = strlen(c->game);
    return !strncmp(p->dir, c->game, n) && (p->dir[n] == 0 || p->dir[n] == '\\');
}

static int hr_window_matches(const hr_rule *r, const hr_win *w)
{
    const char *field = r->match == HR_MATCH_TITLE ? w->title : w->cls;
    if (hr_is_protection(w->title) || hr_is_protection(w->cls)) return 0;
    return hr_contains(field, r->text);
}

/* One look. Returns 1 when the supervisor is done (the second program was closed or the game never came), else 0. */
static int hr_step(hr_state *s, const hr_config *c, const hr_os *os)
{
    static hr_proc procs[HR_MAX_PROCS];
    static hr_win wins[HR_MAX_WINS];
    unsigned now = os->now_ms(os->user);
    int np = os->list_processes(os->user, procs, HR_MAX_PROCS), nw, i, j, game_now = 0;

    for (i = 0; i < np; i++) if (procs[i].pid != os->self_pid && hr_is_game_process(c, &procs[i]) && !hr_is_protection(procs[i].name)) { game_now = 1; break; }
    if (game_now) { s->game_seen = 1; s->has_last = 1; s->last_game_ms = now; }

    if (c->nrules > 0) {
        nw = os->list_windows(os->user, wins, HR_MAX_WINS);
        for (j = 0; j < s->ntrack; j++) s->track[j].alive = 0;
        for (i = 0; i < nw; i++) {
            int r;
            for (r = 0; r < c->nrules; r++) {
                int k, found = -1;
                if (!hr_window_matches(&c->rules[r], &wins[i])) continue;
                for (k = 0; k < s->ntrack; k++) if (s->track[k].rule == r && s->track[k].handle == wins[i].handle) { found = k; break; }
                if (found < 0) {
                    if (s->ntrack >= HR_MAX_TRACK) continue;
                    found = s->ntrack++;
                    s->track[found].rule = r; s->track[found].handle = wins[i].handle; s->track[found].first_ms = now; s->track[found].done = 0;
                }
                s->track[found].alive = 1;
                if (!s->track[found].done && now - s->track[found].first_ms >= c->rules[r].delay_ms) {
                    os->apply(os->user, wins[i].handle, c->rules[r].action);
                    s->track[found].done = 1;
                    s->applied++;
                }
            }
        }
        /* A window that is gone is forgotten (a handle can be used again by another window). */
        for (j = 0, i = 0; j < s->ntrack; j++) if (s->track[j].alive) s->track[i++] = s->track[j];
        s->ntrack = i;
    }

    {
        int over = (s->game_seen && !game_now && s->has_last && now - s->last_game_ms >= HR_END_GRACE_MS)
                || (!s->game_seen && now - s->start_ms >= (c->wait_s + HR_NEVER_STARTED_S) * 1000u);
        if (!over) return 0;
        if (c->stop && c->second[0]) {
            for (i = 0; i < np; i++) {
                if (procs[i].pid != os->self_pid && !strcmp(procs[i].name, c->second) && !hr_is_protection(procs[i].name)) {
                    os->terminate(os->user, procs[i].pid);
                    s->stopped++;
                }
            }
        }
        return 1;
    }
}

#endif /* BCD_HELPER_CORE_H */
