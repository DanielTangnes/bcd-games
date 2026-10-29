#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""tools/patch-wine-guest-log-renpy.py: a Ren'Py game's traceback.txt, stderr.txt, errors.txt and log.txt are mirrored too; no Wine runs.

Doki Doki Literature Club (48B1X4, NTR3Y8, 6AHQMM: builds 600, 611, 622, three devices) and Coming Out on Top (NQZKVF, build 592)
end the same way: the Python 2.7 child process of a Ren'Py game calls NtTerminateProcess(exit_code=0xffffffff) right after
pyexpat.pyd with no message and no window. The reason can only be in the files Ren'Py writes its Python errors to, and the
[guest-log] mirror took *.log and output_log.txt only.

1. Applies the patch to the mirror as tools/patch-wine-guest-log.py writes it (a skeleton file.c), with and without
   tools/patch-wine-guest-log-service.py applied first (the pinned gate and the service-patched gate), and, when the wine
   checkout is present, to the pinned dlls/ntdll/unix/file.c: once, then "already patched"; a file without the mirror fails by
   name and is not written; only the helper and the gate change.
2. Compiles the patched helper region and writes real files: a traceback.txt, log.txt, errors.txt and stderr.txt line that
   mentions an error is mirrored (and the file announced once), a line of them without a keyword is not, a settings.txt or
   notes.txt is still refused, *.log and output_log.txt behave as before, MADEIRA_GUEST_LOG=0 turns it all off.
"""
from pathlib import Path
import os, re, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
mirror = root / "tools/patch-wine-guest-log.py"
service = root / "tools/patch-wine-guest-log-service.py"
renpy = root / "tools/patch-wine-guest-log-renpy.py"
wine = Path(os.environ.get("WINE_SRC", root / "wine"))
real = wine / "dlls/ntdll/unix/file.c"

skeleton = """#include <errno.h>
#include <fcntl.h>
#include <limits.h>

/******************************************************************************
 *              NtWriteFile   (NTDLL.@)
 */
NTSTATUS WINAPI NtWriteFile( void )
{
done:
    send_completion = cvalue != 0;

err:
    if (needs_close) close( unix_handle );

    if (type == FD_TYPE_SERIAL && (status == STATUS_SUCCESS || status == STATUS_PENDING))
        set_pending_write( handle );
}
"""


def run(script, path):
    return subprocess.run([sys.executable, str(script), str(path)], capture_output=True, text=True)


def without_helper(text):
    """The file with the Ren'Py helper and its call in the gate taken out: it must equal the unpatched file."""
    if "static int ios_guest_log_renpy_file" in text:
        a = text.index("/* madeira-bcd: [guest-log] renpy")
        b = text.index("static void ios_guest_log_mirror(")
        text = text[:a] + text[b:]
    return text.replace(" && !ios_guest_log_renpy_file( name )) goto out;", ") goto out;")


with tempfile.TemporaryDirectory() as t:
    t = Path(t)
    sources = [("skeleton", skeleton, False), ("skeleton + service patch", skeleton, True)]
    if real.exists():
        sources.append(("wine file.c", real.read_text(), False))
    else:
        print("note: no wine checkout (%s); only the skeleton is patched" % real)
    patched = None
    for name, text, with_service in sources:
        p = t / "file.c"
        p.write_text(text)
        if "static void ios_guest_log_mirror" not in text:
            r = run(renpy, p)
            assert r.returncode != 0 and "mirror is not in" in r.stderr and p.read_text() == text, (name, r)   # no mirror: fails by name
            r = run(mirror, p)
            assert r.returncode == 0 and "mirror added" in r.stdout, (name, r)
        if with_service and "svc" not in p.read_text():
            r = run(service, p)
            assert r.returncode == 0, (name, r.stderr)
        before = p.read_text()
        r1, r2 = run(renpy, p), run(renpy, p)
        assert r1.returncode == 0 and "applied" in r1.stdout, (name, r1)
        assert r2.returncode == 0 and "already patched" in r2.stdout, (name, r2)
        after = p.read_text()
        assert after.count("madeira-bcd: [guest-log] renpy") == 1 and after.count("ios_guest_log_renpy_file( name )") == 1, name
        assert without_helper(after) == before, name + ": more than the helper and the gate changed"
        # A file whose gate was moved is refused, not half-patched.
        q = t / "moved.c"
        q.write_text(before.replace('strcasecmp( name, "output_log.txt" )) goto out;', 'strcasecmp( name, "x" )) goto out;'))
        r = run(renpy, q)
        assert r.returncode != 0 and "gate was not found" in r.stderr and "renpy" not in q.read_text().replace("tools/patch", ""), (name, r)
        # The compiled helper is the skeleton's: in CI the real file.c already carries the earlier mirror patches (the service one
        # uses Wine's PEB/WCHAR types), so its region does not build alone; the real file is only checked to take the patch once.
        if not with_service and patched is None: patched = after
        print("ok   %s: applies once, only the helper and the gate change; a moved gate is refused" % name)

    region = patched[patched.index("/* guest-log-test:begin"):patched.index("/* guest-log-test:end */")]
    harness = r"""
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
static unsigned int GetCurrentThreadId(void) { return 0x24; }
""" + region + r"""
static int open_file( const char *dir, const char *name )
{
    char p[512]; snprintf( p, sizeof(p), "%s/%s", dir, name );
    return open( p, O_CREAT | O_TRUNC | O_WRONLY, 0644 );
}
static void put( int fd, const char *s ) { ios_guest_log_mirror( fd, s, (unsigned)strlen( s ) ); }
int main( int argc, char **argv )
{
    const char *dir = argv[1];
    int tb = open_file( dir, "traceback.txt" ), lg = open_file( dir, "LOG.TXT" ), er = open_file( dir, "errors.txt" );
    int se = open_file( dir, "stderr.txt" ), st = open_file( dir, "settings.txt" ), nt = open_file( dir, "notes.txt" );
    int ol = open_file( dir, "output_log.txt" ), gl = open_file( dir, "Game.log" );
    put( tb, "I'm sorry, but an uncaught exception occurred.\n" );                                     /* "exception" */
    put( tb, "  File \"renpy/bootstrap.py\", line 316, in bootstrap\n" );                                /* no keyword */
    put( tb, "ImportError: No module named renpy.display.draw\n" );                                      /* "error" */
    put( lg, "Ren'Py 6.99.12.4\nPlatform: Windows-10\nfailed to open the display\n" );                  /* only the last one */
    put( er, "Parsing the script failed.\n" );
    put( se, "IOError: [Errno 2] No such file or directory: 'game/script.rpyc'\n" );
    put( st, "error in a settings file\n" );                                                             /* still not a log */
    put( nt, "error in a notes file\n" );
    put( ol, "[Render] Display adapter: Apple GPU\n" );                                                  /* as before */
    put( gl, "12:00:01 > [NxApp] Failed to get GPU Driver Info\n" );
    return 0;
}
"""
    c = t / "gl.c"; c.write_text(harness)
    exe = t / "gl"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-fsanitize=address,undefined",
                    str(c), "-o", str(exe)], check=True)

    def run_exe(env_extra):
        d = tempfile.mkdtemp(dir=t)
        env = {k: v for k, v in os.environ.items() if not k.startswith("MADEIRA_GUEST_LOG")}
        env.update(env_extra)
        r = subprocess.run([str(exe), d], capture_output=True, text=True, env=env)
        assert r.returncode == 0, (env_extra, r.returncode, r.stderr)
        return r.stderr.splitlines()

    lines = run_exe({})
    body = [re.sub(r"^\[guest-log\] #\d+ tid=0024 ", "", l) for l in lines if re.match(r"\[guest-log\] #\d+", l)]
    files = [os.path.basename(l.split("file ", 1)[1]) for l in lines if l.startswith("[guest-log] file ")]
    assert body == ["I'm sorry, but an uncaught exception occurred.",
                    "ImportError: No module named renpy.display.draw",
                    "failed to open the display",
                    "Parsing the script failed.",
                    "IOError: [Errno 2] No such file or directory: 'game/script.rpyc'",
                    "[Render] Display adapter: Apple GPU",
                    "12:00:01 > [NxApp] Failed to get GPU Driver Info"], body
    assert files == ["traceback.txt", "LOG.TXT", "errors.txt", "stderr.txt", "output_log.txt", "Game.log"], files
    print("ok   default mode: the four Ren'Py files' error lines are mirrored (a line without a keyword is not), the files are named once,"
          " settings.txt and notes.txt stay out, *.log and output_log.txt as before")
    assert [l for l in run_exe({"MADEIRA_GUEST_LOG": "0"}) if re.match(r"\[guest-log\] #\d+", l)] == []
    all_body = [l for l in run_exe({"MADEIRA_GUEST_LOG": "all"}) if re.match(r"\[guest-log\] #\d+", l)]
    assert len(all_body) == 3 + 3 + 1 + 1 + 1 + 1 and not any("settings" in l or "notes" in l for l in all_body), all_body
    print("ok   MADEIRA_GUEST_LOG=0 turns it off and =all mirrors every line of the four files")

print("PASS: guest-log renpy")
