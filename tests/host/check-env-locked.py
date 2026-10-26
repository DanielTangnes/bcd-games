#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""MADEIRA_ENV_LOCKED: a host's own environment names that bcd.cfg's and a game's env.* lines may not replace.

WineProcessBridge.m applies every `env.NAME = value` line of bcd.cfg and of the game's own config with
setenv(k, v, 1), after the host has set its own variables, so a config line could replace what the host set
on purpose (the program a front end was asked to start). MADEIRA_ENV_LOCKED is a comma-separated list of names
the host set deliberately: both loops skip those names and say so in the log.

  1. madeira_env_is_locked() is compiled on the host and tried with: no variable (nothing locked), a list, spaces
     around names, a name that only starts like a locked one, an empty name, a trailing comma;
  2. both export loops (bcd.cfg's and the game's) test the name before setenv, and log "[madeira-env] ... is set by
     the app; the config value is ignored";
  3. nothing in BCD sets MADEIRA_ENV_LOCKED, so no session locks anything unless a host asks for it.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + detail) if detail and not cond else ""))
    if not cond:
        ok = False


src = (R / "app/Madeira/WineProcessBridge.m").read_text()
m = re.search(r"static int madeira_env_is_locked\(const char \*name\)\n\{.*?\n\}\n", src, re.S)
check("madeira_env_is_locked() is defined", bool(m))
if m:
    tmp = Path(tempfile.mkdtemp(prefix="env-locked-"))
    try:
        (tmp / "t.c").write_text(
            "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n" + m.group(0) +
            'int main(int c, char **v){ for (int i = 1; i + 1 < c; i += 2) {\n'
            '  if (!strcmp(v[i], "-")) unsetenv("MADEIRA_ENV_LOCKED"); else setenv("MADEIRA_ENV_LOCKED", v[i], 1);\n'
            '  printf("%d", madeira_env_is_locked(v[i + 1])); }\n puts(""); return 0; }\n')
        p = subprocess.run(["clang", "-Wall", "-Werror", str(tmp / "t.c"), "-o", str(tmp / "t")], capture_output=True, text=True)
        check("it builds on the host", p.returncode == 0, p.stderr[-400:])
        if p.returncode == 0:
            cases = [
                ("-", "MADEIRA_EXE", 0, "no variable: nothing is locked"),
                ("", "MADEIRA_EXE", 0, "an empty variable: nothing is locked"),
                ("MADEIRA_EXE", "MADEIRA_EXE", 1, "a listed name"),
                ("MADEIRA_EXE", "MADEIRA_EXEC_FOO", 0, "a name that starts like a locked one is not locked"),
                ("MADEIRA_EXE", "MADEIRA_EX", 0, "a prefix of a locked name is not locked"),
                ("MADEIRA_EXEC_FOO", "MADEIRA_EXE", 0, "a locked name that starts like the asked one"),
                ("MADEIRA_A,MADEIRA_EXE,MADEIRA_B", "MADEIRA_EXE", 1, "a name in the middle of a list"),
                ("MADEIRA_A,MADEIRA_EXE,MADEIRA_B", "MADEIRA_B", 1, "the last name of a list"),
                (" MADEIRA_A , MADEIRA_EXE ", "MADEIRA_EXE", 1, "spaces around names"),
                ("MADEIRA_A,,MADEIRA_EXE,", "MADEIRA_EXE", 1, "empty items and a trailing comma"),
                ("MADEIRA_A", "", 0, "an empty name is never locked"),
                ("MADEIRA_A", "MADEIRA_a", 0, "names are case sensitive (they are environment names)"),
            ]
            args = []
            for lock, name, _, _ in cases:
                args += [lock, name]
            r = subprocess.run([str(tmp / "t")] + args, capture_output=True, text=True)
            got = r.stdout.strip()
            check("it ran", r.returncode == 0 and len(got) == len(cases), r.stdout + r.stderr)
            for (lock, name, want, what), g in zip(cases, got):
                check("  " + what, g == str(want), "lock=%r name=%r got %s want %d" % (lock, name, g, want))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

# 2. both loops
for what, marker in (("bcd.cfg's env.* lines", 'LOG("bcd.cfg env: %{public}s=%{public}s"'),
                     ("the game's own env.* lines", 'LOG("game config env: %{public}s=%{public}s"')):
    at = src.index(marker)
    before = src[max(0, at - 700):at]
    check("%s skip a locked name before setenv" % what,
          "madeira_env_is_locked(k.UTF8String)" in before and before.rindex("madeira_env_is_locked") < before.rindex("setenv(k.UTF8String")
          and "is set by the app; " in before and "the config value is ignored" in before)

# 3. nothing sets the lock
setters = []
for ext in ("*.swift", "*.m", "*.c", "*.h", "*.json", "*.cfg"):
    for f in (R / "app").rglob(ext):
        if f.name == "ConfigCatalog.generated.swift":
            continue   # the settings catalog names the key; it sets nothing
        t = f.read_text(errors="ignore")
        if re.search(r'setenv\(\s*"MADEIRA_ENV_LOCKED"|MADEIRA_ENV_LOCKED"\s*\]\s*=|"env\.MADEIRA_ENV_LOCKED"', t):
            setters.append(f.name)
for f in (R / "recommended").glob("*.json"):
    if "MADEIRA_ENV_LOCKED" in f.read_text(errors="ignore"):
        setters.append(f.name)
check("nothing in the app or the recommended lists sets MADEIRA_ENV_LOCKED", not setters, str(setters))

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
