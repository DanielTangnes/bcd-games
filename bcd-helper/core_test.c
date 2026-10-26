// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host test of bcd-helper/core.h: the file's rules, then the supervisor's look at a fake system (a list of processes and windows that
// the test changes, a clock it moves). Compiled by tests/host/check-bcd-helper.py with the host's clang and the sanitizers.
#include "core.h"

static int failures, checks;
#define CHECK(cond, what) do { checks++; if (!(cond)) { failures++; printf("FAIL %s\n", what); } else printf("ok   %s\n", what); } while (0)

/* ------------------------------------------------------------ a fake system */
typedef struct {
    unsigned now;
    hr_proc procs[64]; int np;
    hr_win wins[64]; int nw;
    struct { hr_u64 handle; hr_action action; } applied[64]; int napplied;
    unsigned killed[16]; int nkilled;
} fake;

static unsigned f_now(void *u) { return ((fake *)u)->now; }
static void f_sleep(void *u, unsigned ms) { ((fake *)u)->now += ms; }
static int f_procs(void *u, hr_proc *out, int max) { fake *f = u; int n = f->np < max ? f->np : max; memcpy(out, f->procs, n * sizeof *out); return n; }
static int f_wins(void *u, hr_win *out, int max) { fake *f = u; int n = f->nw < max ? f->nw : max; memcpy(out, f->wins, n * sizeof *out); return n; }
static void f_apply(void *u, hr_u64 h, hr_action a) { fake *f = u; f->applied[f->napplied].handle = h; f->applied[f->napplied++].action = a; }
static void f_kill(void *u, unsigned pid) { fake *f = u; f->killed[f->nkilled++] = pid; }

static void add_proc(fake *f, unsigned pid, const char *name, const char *dir)
{
    hr_proc *p = &f->procs[f->np++];
    p->pid = pid; strcpy(p->name, name); strcpy(p->dir, dir);
}
static void remove_proc(fake *f, unsigned pid)
{
    int i, j = 0;
    for (i = 0; i < f->np; i++) if (f->procs[i].pid != pid) f->procs[j++] = f->procs[i];
    f->np = j;
}
static void add_win(fake *f, hr_u64 h, unsigned pid, const char *title, const char *cls)
{
    hr_win *w = &f->wins[f->nw++];
    w->handle = h; w->pid = pid; strcpy(w->title, title); strcpy(w->cls, cls);
}
static hr_os os_for(fake *f) { hr_os o = { f, f_now, f_sleep, f_procs, f_wins, f_apply, f_kill, 99 }; return o; }

int main(void)
{
    hr_config c;
    char err[160];

    /* ---------------------------------------------------------- the file */
    CHECK(hr_parse_config("# a comment\ngame=C:\\Games\\Foo\\\nprogram=Foo.EXE\nsecond=Tool.exe\nstop=1\nwait=5\n"
                          "rule=raise|title|Final Fantasy IX|1000\nrule=minimize-restore|class|UnityWndClass|0\nrule=opaque|title|Launcher|250\n", &c, err, sizeof err) == 0, "a full file reads");
    CHECK(!strcmp(c.game, "c:\\games\\foo") && !strcmp(c.program, "foo.exe") && !strcmp(c.second, "tool.exe") && c.stop == 1 && c.wait_s == 5, "the game, program, second program, stop and wait");
    CHECK(c.nrules == 3 && c.rules[0].action == HR_RAISE && c.rules[0].match == HR_MATCH_TITLE && !strcmp(c.rules[0].text, "Final Fantasy IX") && c.rules[0].delay_ms == 1000, "rule 1");
    CHECK(c.rules[1].action == HR_MINIMIZE_RESTORE && c.rules[1].match == HR_MATCH_CLASS && c.rules[1].delay_ms == 0 && c.rules[2].action == HR_OPAQUE && c.rules[2].delay_ms == 250, "rules 2 and 3");
    CHECK(hr_parse_config("log=C:\\bcd-games\\x.log\n", &c, err, sizeof err) == 0 && !strcmp(c.log, "C:\\bcd-games\\x.log") && hr_parse_config("log=relative.log\n", &c, err, sizeof err) == -1 && hr_parse_config("log=\n", &c, err, sizeof err) == 0 && c.log[0] == 0, "a log path is a path on a drive, or empty");
    CHECK(hr_parse_config("stop=0\nwait=999\nrule=raise|title|x|9999999\n", &c, err, sizeof err) == 0 && c.stop == 0 && c.wait_s == 0 && c.rules[0].delay_ms == 60000, "limits: wait over 300 is none, a delay over a minute is a minute");
    CHECK(hr_parse_config("rule=raise|title|Easy Anti-Cheat Launch Error|1000\n", &c, err, sizeof err) == -1 && strstr(err, "anti-cheat"), "a rule that names an anti-cheat window is refused");
    CHECK(hr_parse_config("rule=raise|class|BattlEye Launcher|1\n", &c, err, sizeof err) == -1, "a rule that names BattlEye is refused");
    CHECK(hr_parse_config("rule=close|title|x|1\n", &c, err, sizeof err) == -1, "an action that is not offered is refused");
    CHECK(hr_parse_config("rule=raise|name|x|1\n", &c, err, sizeof err) == -1 && hr_parse_config("rule=raise|title\n", &c, err, sizeof err) == -1, "a malformed rule is refused");
    CHECK(hr_parse_config("program=..\\evil.exe\n", &c, err, sizeof err) == -1 && hr_parse_config("second=a/b.exe\n", &c, err, sizeof err) == -1 && hr_parse_config("program=foo.dll\n", &c, err, sizeof err) == -1, "program names are plain .exe file names");
    CHECK(hr_parse_config("nonsense=1\n", &c, err, sizeof err) == -1 && hr_parse_config("no equals sign\n", &c, err, sizeof err) == -1, "an unknown key and a line with no = are refused");
    {
        char big[4096] = "";
        int i;
        for (i = 0; i < 17; i++) strcat(big, "rule=raise|title|x|1\n");
        CHECK(hr_parse_config(big, &c, err, sizeof err) == -1, "more than 16 rules are refused");
    }
    CHECK(hr_is_protection("EasyAntiCheat_EOS.exe") && hr_is_protection("BEClient_x64.exe") && hr_is_protection("vgc.exe") && !hr_is_protection("Final Fantasy IX") && !hr_is_protection("Foo.exe"), "protection names");

    /* ---------------------------------------------------------- the supervisor */
    {
        fake f; hr_os os; hr_state s; hr_config cfg;
        memset(&f, 0, sizeof f);
        os = os_for(&f);
        hr_parse_config("game=C:\\Games\\Foo\nprogram=foo.exe\nsecond=tool.exe\nstop=1\nwait=0\n"
                        "rule=raise|title|Foo Game|1000\nrule=opaque|class|BadWindow|0\nrule=minimize-restore|title|Launcher|500\n", &cfg, err, sizeof err);
        f.now = 10000;
        hr_init(&s, &os);
        add_proc(&f, 7, "tool.exe", "c:\\tools");
        add_proc(&f, 3, "services.exe", "c:\\windows\\system32");
        CHECK(hr_step(&s, &cfg, &os) == 0 && !s.game_seen, "before the game starts nothing happens");

        add_proc(&f, 20, "foo.exe", "c:\\games\\foo");
        add_win(&f, 0x100, 20, "Launcher", "LauncherClass");
        f.now += 500;
        CHECK(hr_step(&s, &cfg, &os) == 0 && s.game_seen && f.napplied == 0, "the game seen; a rule waits for its delay");
        f.now += 600;
        CHECK(hr_step(&s, &cfg, &os) == 0 && f.napplied == 1 && f.applied[0].handle == 0x100 && f.applied[0].action == HR_MINIMIZE_RESTORE, "after 500 ms the launcher is minimised and restored");
        f.now += 5000;
        hr_step(&s, &cfg, &os);
        CHECK(f.napplied == 1, "once: a rule is not applied again to the same window");

        add_win(&f, 0x200, 20, "Foo Game - 1280x720", "UnityWndClass");
        add_win(&f, 0x300, 20, "x", "BadWindow");
        f.now += 100;
        hr_step(&s, &cfg, &os);
        CHECK(f.napplied == 2 && f.applied[1].handle == 0x300 && f.applied[1].action == HR_OPAQUE, "a rule with no delay acts at once, on the class");
        f.now += 1000;
        hr_step(&s, &cfg, &os);
        CHECK(f.napplied == 3 && f.applied[2].handle == 0x200 && f.applied[2].action == HR_RAISE, "a title rule matches a part of the title, in any case");

        /* a window of a protection program is left alone even if a rule matches its other field */
        add_win(&f, 0x400, 30, "Easy Anti-Cheat", "BadWindow");
        f.now += 100;
        hr_step(&s, &cfg, &os);
        CHECK(f.napplied == 3, "a protection program's window is never touched");

        /* the window goes and a new one takes the handle: it is looked at again */
        f.nw = 0;
        add_win(&f, 0x200, 20, "Something else", "X");
        f.now += 100;
        hr_step(&s, &cfg, &os);
        f.nw = 0;
        add_win(&f, 0x200, 20, "Foo Game again", "UnityWndClass");
        hr_step(&s, &cfg, &os);
        f.now += 1100;
        hr_step(&s, &cfg, &os);
        CHECK(f.napplied == 4 && f.applied[3].handle == 0x200, "a handle used again by another window is a new window");

        /* the game ends */
        remove_proc(&f, 20);
        f.now += 3000;
        CHECK(hr_step(&s, &cfg, &os) == 0 && f.nkilled == 0, "gone for 3 s: not over yet");
        f.now += 2500;
        CHECK(hr_step(&s, &cfg, &os) == 1 && f.nkilled == 1 && f.killed[0] == 7, "gone for 5 s: the second program is closed, nothing else");
    }
    {   /* the game's own other processes keep it alive */
        fake f; hr_os os; hr_state s; hr_config cfg;
        memset(&f, 0, sizeof f); os = os_for(&f);
        hr_parse_config("game=C:\\Games\\Foo\nprogram=foo.exe\nsecond=tool.exe\nwait=0\n", &cfg, err, sizeof err);
        f.now = 1000; hr_init(&s, &os);
        add_proc(&f, 7, "tool.exe", "c:\\games\\foo");   /* the second program lives in the game's folder */
        add_proc(&f, 20, "launcher.exe", "c:\\games\\foo");
        hr_step(&s, &cfg, &os);
        CHECK(s.game_seen, "a program in the game's folder is the game");
        remove_proc(&f, 20);
        add_proc(&f, 21, "real-game.exe", "c:\\games\\foo\\bin");
        f.now += 8000;
        CHECK(hr_step(&s, &cfg, &os) == 0 && f.nkilled == 0, "the launcher ended but another program of the folder runs: the game goes on");
        remove_proc(&f, 21);
        f.now += 1000; hr_step(&s, &cfg, &os);
        f.now += 5000;
        CHECK(hr_step(&s, &cfg, &os) == 1 && f.nkilled == 1 && f.killed[0] == 7, "then it ends, and the second program (in the same folder) is closed");
        CHECK(hr_is_game_process(&cfg, &(hr_proc){ 5, "tool.exe", "c:\\games\\foo" }) == 0 && hr_is_game_process(&cfg, &(hr_proc){ 5, "other.exe", "c:\\games\\foobar" }) == 0, "the second program and a folder with the same start are not the game");
    }
    {   /* the game never comes */
        fake f; hr_os os; hr_state s; hr_config cfg;
        memset(&f, 0, sizeof f); os = os_for(&f);
        hr_parse_config("program=foo.exe\nsecond=tool.exe\nwait=10\n", &cfg, err, sizeof err);
        f.now = 0; hr_init(&s, &os);
        add_proc(&f, 7, "tool.exe", "c:\\tools");
        f.now = 100000; 
        CHECK(hr_step(&s, &cfg, &os) == 0, "within the delay and the grace time: waiting");
        f.now = 191000;
        CHECK(hr_step(&s, &cfg, &os) == 1 && f.nkilled == 1, "the game never came: the second program is closed and the supervisor ends");
    }
    {   /* stop=0 closes nothing */
        fake f; hr_os os; hr_state s; hr_config cfg;
        memset(&f, 0, sizeof f); os = os_for(&f);
        hr_parse_config("program=foo.exe\nsecond=tool.exe\nstop=0\n", &cfg, err, sizeof err);
        f.now = 0; hr_init(&s, &os);
        add_proc(&f, 7, "tool.exe", "c:\\tools"); add_proc(&f, 20, "foo.exe", "c:\\g");
        hr_step(&s, &cfg, &os);
        remove_proc(&f, 20); f.now += 6000;
        CHECK(hr_step(&s, &cfg, &os) == 1 && f.nkilled == 0, "with stop off the second program is left running");
    }
    {   /* a protection process named like the second program is never closed; the supervisor's own pid is never counted */
        fake f; hr_os os; hr_state s; hr_config cfg;
        memset(&f, 0, sizeof f); os = os_for(&f);
        hr_parse_config("program=foo.exe\nsecond=tool.exe\n", &cfg, err, sizeof err);
        f.now = 0; hr_init(&s, &os);
        add_proc(&f, 99, "foo.exe", "c:\\g");   /* this process itself */
        hr_step(&s, &cfg, &os);
        CHECK(!s.game_seen, "the supervisor's own process is never the game");
    }
    {   /* the track table is bounded */
        fake f; hr_os os; hr_state s; hr_config cfg; int i;
        memset(&f, 0, sizeof f); os = os_for(&f);
        hr_parse_config("program=foo.exe\nrule=raise|title|w|0\n", &cfg, err, sizeof err);
        f.now = 0; hr_init(&s, &os);
        add_proc(&f, 20, "foo.exe", "c:\\g");
        for (i = 0; i < 60; i++) add_win(&f, 1000 + i, 20, "w", "c");
        hr_step(&s, &cfg, &os);
        CHECK(s.ntrack == 60 && f.napplied == 60, "many windows are each handled once");
        CHECK(hr_step(&s, &cfg, &os) == 0 && f.napplied == 60, "and not again");
    }
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
