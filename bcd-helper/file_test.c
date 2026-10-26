// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// Reads the supervisor file that BCD's Swift side wrote (tests/host/game_setup_ui_host.swift writes it from a plan) with core.h's own
// reader, and prints what it found, so tests/host/check-bcd-helper.py can compare it with the plan. argv[1] is the file.
#include "core.h"

int main(int argc, char **argv)
{
    static char text[65536];
    hr_config c;
    char err[160] = "";
    FILE *f;
    size_t n;
    int i;
    if (argc < 2 || !(f = fopen(argv[1], "rb"))) { printf("no file\n"); return 2; }
    n = fread(text, 1, sizeof text - 1, f);
    fclose(f);
    text[n] = 0;
    if (hr_parse_config(text, &c, err, sizeof err) != 0) { printf("ERROR %s\n", err); return 1; }
    printf("game=%s\nprogram=%s\nsecond=%s\nstop=%d\nwait=%u\nrules=%d\nlog=%s\n", c.game, c.program, c.second, c.stop, c.wait_s, c.nrules, c.log);
    for (i = 0; i < c.nrules; i++) printf("rule%d=%d|%d|%s|%u\n", i + 1, (int)c.rules[i].action, (int)c.rules[i].match, c.rules[i].text, c.rules[i].delay_ms);
    return 0;
}
