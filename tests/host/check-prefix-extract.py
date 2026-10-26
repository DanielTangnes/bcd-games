#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The prefix tarball extractor (app/Madeira/PrefixExtractor.c) refuses what could write outside its folder.

PrefixExtractor.c unpacks the bundled Wine prefix (a gzipped tar) into the app's container. It is built
here on the host with zlib (with AddressSanitizer and UBSan when clang has them) into a small driver and
given synthetic archives:

  1. a normal archive (prefix/ stripped, nested directories, a file of exactly one block, an empty file,
     a ustar prefix field, names that merely contain dots such as "a..b" and "..hidden") unpacks byte for
     byte and returns 0;
  2. an entry with a ".." component (first, in the middle, last), or an absolute path, makes it return -1
     and writes nothing outside the destination; entries before it stay, which is the old behaviour for
     any failing archive;
  3. a size field that is not octal, or that does not fit an int, or that would overflow the block
     padding, returns -1 (before: a negative size skipped the data and read the next block as a header,
     and a huge one wrapped the padding);
  4. a directory entry with an empty name does not read before the buffer.

Nothing here changes what a well-formed archive does, so the games' prefix is unchanged.
"""
import gzip
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
SRC = R / "app/Madeira/PrefixExtractor.c"
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + (("  " + detail) if detail and not cond else ""))
    if not cond:
        ok = False


tmp = Path(tempfile.mkdtemp(prefix="prefix-extract-"))
try:
    drv = tmp / "driver.c"
    drv.write_text('#include <stdio.h>\n#include "PrefixExtractor.h"\n'
                   'int main(int c, char **v){ return madeira_extract_prefix_tgz(v[1], v[2]) == 0 ? 0 : 3; }\n')
    exe = tmp / "driver"
    base = ["clang", "-std=gnu11", "-O1", "-g", "-I", str(SRC.parent), str(SRC), str(drv), "-lz", "-o", str(exe)]
    p = subprocess.run(base[:1] + ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined"] + base[1:],
                       capture_output=True, text=True)
    if p.returncode != 0:
        p = subprocess.run(base, capture_output=True, text=True)
    check("PrefixExtractor.c builds on the host", p.returncode == 0, p.stderr[-800:])
    if p.returncode != 0:
        sys.exit(1)

    def tar_bytes(members, fmt=tarfile.USTAR_FORMAT):
        """members: (name, bytes | None for a directory)."""
        bio = io.BytesIO()
        with tarfile.open(fileobj=bio, mode="w", format=fmt) as tf:
            for name, data in members:
                ti = tarfile.TarInfo(name)
                if data is None:
                    ti.type = tarfile.DIRTYPE
                    ti.mode = 0o755
                    tf.addfile(ti)
                else:
                    ti.size = len(data)
                    ti.mode = 0o644
                    tf.addfile(ti, io.BytesIO(data))
        return bio.getvalue()

    def header(name, size_field, typ=b"0"):
        h = bytearray(512)
        h[0:len(name)] = name
        h[100:108] = b"0000644\0"
        h[108:116] = b"0000000\0"
        h[116:124] = b"0000000\0"
        h[124:136] = size_field
        h[136:148] = b"00000000000\0"
        h[148:156] = b"        "
        h[156:157] = typ
        h[257:263] = b"ustar\0"
        h[263:265] = b"00"
        h[148:156] = (b"%06o\0 " % sum(h))
        return bytes(h)

    def run(raw, name):
        d = tmp / name
        d.mkdir()
        t = tmp / (name + ".tgz")
        t.write_bytes(gzip.compress(raw))
        dest = d / "dest"
        r = subprocess.run([str(exe), str(t), str(dest)], capture_output=True, text=True)
        return r.returncode, dest, d, r.stderr

    # 1. a normal archive
    payload = bytes(range(256)) * 2   # exactly one block
    members = [("prefix", None), ("prefix/drive_c", None), ("prefix/drive_c/windows", None),
               ("prefix/drive_c/windows/a.txt", b"hello"),
               ("prefix/drive_c/windows/block.bin", payload),
               ("prefix/drive_c/windows/empty", b""),
               ("prefix/drive_c/a..b", b"dots inside"),
               ("prefix/drive_c/..hidden", b"leading dots"),
               ("prefix/drive_c/...", b"three dots"),
               ("prefix/" + "d" * 60 + "/" + "e" * 60 + "/" + "f" * 60 + "/long.txt", b"ustar prefix field")]
    rc, dest, d, err = run(tar_bytes(members), "good")
    check("a normal archive returns 0", rc == 0, err[-400:])
    check("  nested file and its bytes", (dest / "drive_c/windows/a.txt").read_bytes() == b"hello")
    check("  a file of exactly one block", (dest / "drive_c/windows/block.bin").read_bytes() == payload)
    check("  an empty file", (dest / "drive_c/windows/empty").exists() and (dest / "drive_c/windows/empty").stat().st_size == 0)
    check("  names with dots inside are fine", (dest / "drive_c/a..b").read_bytes() == b"dots inside"
          and (dest / "drive_c/..hidden").read_bytes() == b"leading dots"
          and (dest / "drive_c/...").read_bytes() == b"three dots")
    check("  a long path through the ustar prefix field",
          (dest / ("d" * 60 + "/" + "e" * 60 + "/" + "f" * 60 + "/long.txt")).read_bytes() == b"ustar prefix field")

    # 2. escapes
    outside = tmp / "outside"
    cases = {
        "dotdot-first": b"prefix/../../outside/evil.txt",
        "dotdot-middle": b"prefix/drive_c/../../../outside/evil.txt",
        "dotdot-last": b"prefix/drive_c/..",
        "dotdot-bare": b"../outside/evil.txt",
        "absolute": str(outside / "evil.txt").encode(),
    }
    for nm, entry in cases.items():
        raw = header(entry, b"00000000005\0") + b"evil!".ljust(512, b"\0") + b"\0" * 1024
        d0 = tmp / ("esc-" + nm)
        d0.mkdir()
        rc, dest, d, err = run(raw, "esc-" + nm + "-run")
        leaked = list(tmp.rglob("evil.txt"))
        check("%s is refused" % nm, rc == 3 and "unsafe path rejected" in err, err[-300:])
        check("  nothing written outside the destination (%s)" % nm, not leaked, str(leaked))
    # an archive with good entries first: those stay, the bad one stops the extraction
    raw = header(b"prefix/ok.txt", b"00000000004\0") + b"fine".ljust(512, b"\0") \
        + header(b"prefix/x/../../outside/evil.txt", b"00000000005\0") + b"evil!".ljust(512, b"\0") + b"\0" * 1024
    rc, dest, d, err = run(raw, "esc-late")
    check("a bad entry after good ones stops the extraction", rc == 3 and (dest / "ok.txt").read_bytes() == b"fine"
          and not list(tmp.rglob("evil.txt")))

    # 3. size fields
    for nm, field in (("size-not-octal", b"0000000089z\0"), ("size-int-max", b"17777777777\0"),
                      ("size-near-int-max", b"17777777000\0"), ("size-huge", b"77777777777\0")):
        raw = header(b"prefix/big.bin", field) + b"x" * 512 + b"\0" * 1024
        rc, dest, d, err = run(raw, nm)
        check("%s is refused" % nm, rc == 3 and "bad size field" in err, err[-300:])
        check("  and no file created for it (%s)" % nm, not (dest / "big.bin").exists() or (dest / "big.bin").stat().st_size == 0)

    # 4. an empty directory name
    raw = header(b"", b"00000000000\0", b"0") + b"\0" * 1024
    rc, dest, d, err = run(raw, "empty-name")
    check("an entry with an empty name does not crash the extractor", "ERROR: AddressSanitizer" not in err
          and "runtime error" not in err, err[-300:])

    # 5. the app's own prefix template (what a first launch unpacks) is accepted whole
    tpl = R / "app/Madeira/prefix-template.tar.gz"
    dest = tmp / "template-dest"
    r = subprocess.run([str(exe), str(tpl), str(dest)], capture_output=True, text=True)
    n = sum(1 for _ in dest.rglob("*")) if dest.exists() else 0
    check("the bundled prefix template unpacks (exit 0, files and directories present)", r.returncode == 0 and n > 100,
          r.stderr[-300:])
    check("  and it has a registry and drive_c", (dest / "drive_c").is_dir() and any(dest.glob("*.reg")))

    # the source carries the three guards
    s = SRC.read_text()
    check("source: parse_octal refuses an overflow", "INT_MAX >> 3" in s)
    check("source: the size field is checked against the padding", "size > INT_MAX - BLOCK" in s)
    check("source: absolute paths and '..' components are refused", "unsafe path rejected" in s and "relname[0] == '/'" in s)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
