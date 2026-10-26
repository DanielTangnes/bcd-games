#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The guest's stdin and stdout on pipes, and a forced console: opt-in, nothing changes unless asked.

WineProcessBridge.m can hand fd 0 and fd 1 of the session to pipes, so a front end that drains them can feed a
console program and read its output apart from the runtime's log. env_ios.c can tag the pipes as a terminal so
Wine builds a console (conhost) anyway. All three are off by default:

  1. stdin pipe: env.MADEIRA_STDIN_PIPE = 1, or Documents/bcd-stdin.txt (its contents seed the pipe);
  2. stdout pipe: env.MADEIRA_STDOUT_PIPE = 1, or Documents/bcd-stdout.txt (stderr stays on bcd-log.txt);
  3. forced console: env.MADEIRA_FORCE_CONSOLE = 1 (set by Documents/bcd-console.txt) and only while the process has
     no console handle yet.

Checks:
  a. the four accessors (madeira_stdin_write / _close / _is_open, madeira_stdout_is_open / _read) are compiled on
     the host over real pipes: write reaches the read end, close gives EOF, a non-blocking read with nothing pending
     is -1/EAGAIN, a closed or never-opened pipe answers -1 / 0;
  b. the source: each block runs only when its flag file exists or its switch is "1"; the pipes are non-blocking on
     the side the app uses; the stdout block leaves fd 2 on the log; a second session closes the earlier end; the
     flag files carry BCD's names; the force-console branch needs the switch, a missing console handle and both
     standard handles;
  c. env_ios.c's compiled shape is covered by the build (get_initial_console); here its guard is read.
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


bridge = (R / "app/Madeira/WineProcessBridge.m").read_text()
header = (R / "app/Madeira/WineProcessBridge.h").read_text()
envc = (R / "build/ntdll-unix/env_ios.c").read_text()

# a. the accessors over real pipes
start = bridge.index("int madeira_stdin_master = -1;")
end = bridge.index("// Thread-local globals for wine_ios_exit longjmp")
chunk = bridge[start:end]
check("the accessors sit together at the top of WineProcessBridge.m", "madeira_stdin_close" in chunk and "madeira_stdout_read" in chunk)
tmp = Path(tempfile.mkdtemp(prefix="guest-pipes-"))
try:
    (tmp / "t.c").write_text(
        "#include <errno.h>\n#include <fcntl.h>\n#include <stdio.h>\n#include <string.h>\n#include <unistd.h>\n"
        + chunk +
        r'''
#define CHECK(c) do { if (!(c)) { printf("FAILED line %d: %s\n", __LINE__, #c); return 1; } } while (0)
int main(void) {
    char b[16];
    /* never opened */
    CHECK(!madeira_stdin_is_open() && !madeira_stdout_is_open());
    CHECK(madeira_stdin_write("x", 1) == -1);
    CHECK(madeira_stdout_read(b, sizeof b) == -1);
    /* stdin: a pipe whose write end the app holds */
    int in[2]; CHECK(pipe(in) == 0);
    madeira_stdin_master = in[1];
    CHECK(madeira_stdin_is_open());
    CHECK(madeira_stdin_write("hello", 5) == 5);
    CHECK(read(in[0], b, sizeof b) == 5 && !memcmp(b, "hello", 5));
    madeira_stdin_close();
    CHECK(!madeira_stdin_is_open() && madeira_stdin_master == -1);
    CHECK(read(in[0], b, sizeof b) == 0);            /* EOF for the guest */
    madeira_stdin_close();                           /* a second close is harmless */
    CHECK(madeira_stdin_write("x", 1) == -1);
    /* stdout: a non-blocking read end */
    int out[2]; CHECK(pipe(out) == 0);
    fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL, 0) | O_NONBLOCK);
    madeira_stdout_master = out[0];
    CHECK(madeira_stdout_is_open());
    errno = 0; CHECK(madeira_stdout_read(b, sizeof b) == -1 && errno == EAGAIN);
    CHECK(write(out[1], "abc", 3) == 3);
    CHECK(madeira_stdout_read(b, sizeof b) == 3 && !memcmp(b, "abc", 3));
    CHECK(madeira_stdout_read(NULL, 4) == -1 && madeira_stdout_read(b, 0) == -1);
    close(out[1]);
    CHECK(madeira_stdout_read(b, sizeof b) == 0);    /* EOF */
    puts("ok"); return 0;
}
''')
    p = subprocess.run(["clang", "-Wall", "-Werror", "-Wno-unused-function", str(tmp / "t.c"), "-o", str(tmp / "t")],
                       capture_output=True, text=True)
    check("the accessors build on the host", p.returncode == 0, p.stderr[-500:])
    if p.returncode == 0:
        r = subprocess.run([str(tmp / "t")], capture_output=True, text=True)
        check("  and behave over real pipes (write, close to EOF, non-blocking read, never-opened)",
              r.returncode == 0 and r.stdout.strip().endswith("ok"), r.stdout + r.stderr)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

hdr = re.sub(r"\s+", " ", header)
check("WineProcessBridge.h declares the accessors",
      all(x in hdr for x in ("int madeira_stdin_is_open(void);", "long madeira_stdin_write(const void *buf, unsigned long len);",
                             "void madeira_stdin_close(void);", "int madeira_stdout_is_open(void);",
                             "long madeira_stdout_read(void *buf, unsigned long len);")))

# b. the opt-in blocks
so = bridge.index("hand the guest's stdout to a pipe")
blk = bridge[so:bridge.index("// Pick which exe to run", so)]
check("the stdout pipe needs its flag file or MADEIRA_STDOUT_PIPE=1",
      re.search(r'fileExistsAtPath:flag\] \|\|\s*\(stdout_opt && stdout_opt\[0\] == \'1\'\)', blk))
check("  the flag file is Documents/bcd-stdout.txt", '@"bcd-stdout.txt"' in blk)
check("  it moves fd 1 only (dup2 onto STDOUT_FILENO, never STDERR_FILENO)", "dup2(fds[1], STDOUT_FILENO)" in blk
      and "dup2(fds[1], STDERR_FILENO)" not in blk and "dup2(fds[0], STDERR_FILENO)" not in blk)
check("  its read end is non-blocking", "fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL, 0) | O_NONBLOCK)" in blk)
check("the stdin pipe needs its seed file or MADEIRA_STDIN_PIPE=1",
      re.search(r'if \(seed \|\| \(stdin_opt && stdin_opt\[0\] == \'1\'\)\)', blk))
check("  the seed is Documents/bcd-stdin.txt", '@"bcd-stdin.txt"' in blk)
check("  fd 0 reads the pipe (dup2 onto STDIN_FILENO) and the write end is non-blocking",
      "dup2(fds[0], STDIN_FILENO)" in blk and "fcntl(fds[1], F_SETFL, fl | O_NONBLOCK)" in blk)
check("  a second session closes the earlier ends first",
      "close(madeira_stdout_master)" in blk and "close(madeira_stdin_master)" in blk)
check("the console flag file is Documents/bcd-console.txt and only sets MADEIRA_FORCE_CONSOLE",
      '@"bcd-console.txt"' in blk and 'setenv("MADEIRA_FORCE_CONSOLE", "1", 1)' in blk)
check("the blocks come after the log redirect and after bcd.cfg's env.* lines were exported",
      bridge.index("hand the guest's stdout to a pipe") > bridge.index('LOG("bcd.cfg env: %{public}s=%{public}s"')
      and bridge.index("hand the guest's stdout to a pipe") > bridge.index("dup2(logfd, STDOUT_FILENO)"))
check("no 'madeira-stdin/stdout/console' file name is left", not re.search(r'madeira-(stdin|stdout|console)\.txt', bridge + header))

# c. env_ios.c
i = envc.index('const char *force = getenv( "MADEIRA_FORCE_CONSOLE" );')
g = envc[max(0, i - 120):i + 200]
check("the forced console needs MADEIRA_FORCE_CONSOLE=1, no console handle yet, and both std handles",
      "if (!params->ConsoleHandle)" in g and "force && *force == '1' && params->hStdInput && params->hStdOutput" in envc[i:i + 260])
check("  and it comes before the 'no console' fallback",
      i < envc.index("params->ConsoleHandle = CONSOLE_HANDLE_SHELL_NO_WINDOW;", i))

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
