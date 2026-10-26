#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""BCD's runtime installer (bcd-runtimes/, round 603): the Start menu's "BCD Runtimes" folder.

bcd-runtimes-x64.exe downloads Microsoft's XNA Framework 4.0 and DirectX (June 2010) runtimes, NVIDIA's PhysX 9.21.0713 and the OpenAL
installer from their vendors when the person presses its button, checks size and SHA-256, and installs them. Nothing of it runs on
this host (it is a Windows program); this check runs the parts that do not need Windows, and proves the rest from the source:

  1. core.h on the host, with ASan and UBSan, against Python's hashlib and zlib and zipfile: SHA-256 (any chunking), CRC-32, the raw
     deflate decoder (every zlib level and strategy, stored/fixed/dynamic blocks, damaged and short input), the ZIP reader (stored and
     deflated entries, case-insensitive names, a damaged CRC, truncation, garbage), and the rules for URLs and redirects (HTTPS only,
     one host, no user name, no other port; a redirect to another host or to HTTP is refused).
  2. The table of runtimes: file names, hosts, SHA-256 and sizes in the form the program needs, every URL on its own allow-list;
     the Start menu rows name the same ids.
  3. The path patterns that decide "installed" (a GAC folder with any version below it) on a fake disk.
  4. PhysX (physx.h) on a fake disk and a fake registry: the table is NVIDIA's own manifest (a digest of it is pinned here: a change must
     be deliberate), every file lands where the manifest says, the registry values are written in the right views, a missing file is
     counted, a 32-bit Windows skips the 64-bit rows, a newer PhysX is never replaced.
  5. The DirectX cabinet reader (cabs.h) driven through a stand-in for cabinet.dll that calls the real callbacks in the real order, on
     fake DirectX cabinets: only DLLs whose name is free are written, a name that exists keeps its bytes, a copy cut short leaves no
     file behind (not even a part file), nothing outside the two Windows folders is touched, the Managed DirectX cabinets, setup
     files and path tricks are skipped.
  6. The program's source against the promises (HTTPS and the host list, the checksum before anything runs, CREATE_NEW and a part
     file for DLLs, deletion only below the runtimes folder), compiled for Windows (-Wall -Wextra -Werror) when llvm-mingw is there and
     compared with the tracked program, byte for byte; the tracked program's PE headers; the build script, the workflow, the notices.

With BCD_CHECK_RUNTIMES_NET=1 each pinned URL is asked for its size (a HEAD request, nothing is downloaded) and must answer with the
pinned size. With BCD_RUNTIMES_FILES=<folder> holding the four vendor files, their SHA-256 must be the pinned ones.
"""
import hashlib
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "bcd-runtimes"
failures = 0


def check(what, ok, detail=None):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1
        if detail is not None:
            print("       " + str(detail)[:700])


TMP = Path(tempfile.mkdtemp(prefix="check-bcd-runtimes-"))

# ---------------------------------------------------------------- build the host driver
clang = shutil.which("clang") or shutil.which("cc")
CT = TMP / "core_test"
cmd = [clang, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
       "-I", str(SRC), "-o", str(CT), str(SRC / "core_test.c")]
r = subprocess.run(cmd, capture_output=True, text=True)
check("core_test.c builds for the host with -Wall -Wextra -Werror and ASan/UBSan", r.returncode == 0, r.stderr[-1500:])
if r.returncode != 0:
    print("check-bcd-runtimes: FAIL (no host driver)")
    sys.exit(1)

ENV = dict(os.environ, ASAN_OPTIONS="detect_leaks=0")


def ct(*args, check_rc=None):
    p = subprocess.run([str(CT)] + [str(a) for a in args], capture_output=True, text=True, env=ENV)
    if "AddressSanitizer" in p.stderr or "runtime error" in p.stderr:
        check("sanitizer clean: core_test " + " ".join(str(a) for a in args)[:80], False, p.stderr[-800:])
    return p


def put(name, data):
    path = TMP / name
    path.write_bytes(data)
    return path


rnd = random.Random(603)

def batch(cmds):
    """Runs many small commands in ONE process (core_test batch): [(exit code, output)], one per command. The sanitizers watch all of them."""
    f = TMP / "batch.txt"
    f.write_text("\n".join("\t".join(str(a) for a in c) for c in cmds) + "\n")
    p = subprocess.run([str(CT), "batch", str(f)], capture_output=True, text=True, env=ENV)
    if p.returncode != 0 or "AddressSanitizer" in p.stderr or "runtime error" in p.stderr:
        check("a batch of %d commands ran without a crash or a sanitizer report" % len(cmds), False, p.stderr[-1200:])
        return [(99, "")] * len(cmds)
    out, cur = [], []
    for line in p.stdout.split("\n"):
        if line.startswith("@@ "):
            out.append((int(line[3:]), "\n".join(cur)))
            cur = []
        else:
            cur.append(line)
    if len(out) != len(cmds):
        check("a batch of %d commands gave %d answers" % (len(cmds), len(out)), False, p.stdout[-600:])
        return [(98, "")] * len(cmds)
    return out


# ---------------------------------------------------------------- 1a. SHA-256
vectors = [b"", b"abc", b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", b"a" * 1000000, bytes(range(256)) * 17]
cmds, want = [], []
for i, v in enumerate(vectors):
    f = put("v%d.bin" % i, v)
    for chunk in (1, 7, 63, 64, 65, 4096, 100000):
        if chunk == 1 and len(v) > 5000:
            continue
        cmds.append(("sha256", f, chunk))
        want.append(hashlib.sha256(v).hexdigest())
res = batch(cmds)
bad = [(c, o) for c, (rc, o), w in zip(cmds, res, want) if o.strip() != w]
check("SHA-256 equals hashlib for the standard vectors, a million 'a' and 256-byte runs, fed in pieces of 1 to 100000 bytes (%d runs)" % len(cmds), not bad, bad[:2])
cmds, want = [], []
for n in list(range(0, 200)) + [4095, 4096, 4097, 65535, 65536, 65537]:
    v = rnd.randbytes(n)
    cmds.append(("sha256", put("r%d.bin" % n, v), rnd.choice([1, 13, 64, 77, 1000])))
    want.append(hashlib.sha256(v).hexdigest())
res = batch(cmds)
bad = [(c[2], o) for c, (rc, o), w in zip(cmds, res, want) if o.strip() != w]
check("SHA-256 equals hashlib for every size 0..199 and around the block and buffer sizes (padding edge cases)", not bad, bad[:2])
f = put("abc.bin", b"abc")
good = hashlib.sha256(b"abc").hexdigest()
res = batch([("sha256is", f, good), ("sha256is", f, good.upper())] + [("sha256is", f, bad) for bad in (good[:-1], good + "0", good[:-1] + ("0" if good[-1] != "0" else "1"), "z" * 64, "")])
check("sha256_is accepts the digest in either case and nothing else (short, long, one digit off, non-hex, empty)",
      [o.strip() for rc, o in res] == ["1", "1", "0", "0", "0", "0", "0"], res)

# ---------------------------------------------------------------- 1b. CRC-32
cmds, want = [], []
for n in (0, 1, 5, 255, 256, 4097, 100000):
    v = rnd.randbytes(n)
    cmds.append(("crc32", put("c%d.bin" % n, v)))
    want.append("%08x" % (zlib.crc32(v) & 0xFFFFFFFF))
check("CRC-32 equals zlib's", [o.strip() for rc, o in batch(cmds)] == want)

# ---------------------------------------------------------------- 1c. inflate
def raw_deflate(data, level=6, strategy=zlib.Z_DEFAULT_STRATEGY, mem=8, wbits=-15):
    c = zlib.compressobj(level, zlib.DEFLATED, wbits, mem, strategy)
    return c.compress(data) + c.flush()


corpora = {
    "empty": b"",
    "one": b"x",
    "text": (b"The quick brown fox jumps over the lazy dog. " * 300) + bytes(range(256)) * 3,
    "zeros": bytes(70000),
    "random": rnd.randbytes(30000),
    "ascending": bytes(i % 251 for i in range(50000)),
    "mixed": rnd.randbytes(3000) + b"abcabcabcabc" * 4000 + rnd.randbytes(3000),
    "runs": b"".join(bytes([rnd.randrange(4)]) * rnd.randrange(1, 400) for _ in range(300)),
}
cmds, info = [], []
for name, data in corpora.items():
    for level in (0, 1, 3, 6, 9):
        for strategy in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED, zlib.Z_HUFFMAN_ONLY, zlib.Z_RLE, zlib.Z_FIXED):
            k = len(cmds)
            cmds.append(("inflate", put("inf%d.in" % k, raw_deflate(data, level, strategy)), len(data), TMP / ("inf%d.out" % k)))
            info.append((name, level, strategy, data))
res = batch(cmds)
bad = [i[:3] for c, (rc, o), i in zip(cmds, res, info) if rc != 0 or Path(c[3]).read_bytes() != i[3]]
check("inflate gives back the data for %d combinations of content, zlib level (stored, fixed and dynamic blocks) and strategy" % len(cmds), not bad, bad[:3])
data = corpora["text"]
comp = raw_deflate(data)
cmds = [("inflate", put("a.in", comp), len(data) - 1, TMP / "o"), ("inflate", put("a.in", comp), len(data) + 1, TMP / "o")]
cmds += [("inflate", put("t%d.in" % cut, comp[:cut]), len(data), TMP / "o") for cut in (0, 1, 2, len(comp) // 2, len(comp) - 1)]
res = batch(cmds)
check("inflate refuses an output size that is too small (-6) or too large (-7)", res[0][1].startswith("BAD -6") and res[1][1].startswith("BAD -7"), res[:2])
check("inflate refuses a stream that ends early", all(rc != 0 for rc, o in res[2:]), res[2:])
cmds = []
for i in range(400):
    d = bytearray(comp)
    for _ in range(rnd.randrange(1, 4)):
        d[rnd.randrange(len(d))] ^= 1 << rnd.randrange(8)
    cmds.append(("inflate", put("fz%d.in" % i, bytes(d)), len(data), TMP / "o"))
res = batch(cmds)
check("400 damaged streams: never a crash or a sanitizer report, only a result (an error code, or a decode that the CRC would catch)", all(rc in (0, 1) for rc, o in res))
res = batch([("inflate", put("rb%d.in" % i, rnd.randbytes(200)), 1000, TMP / "o") for i in range(100)] +
            [("inflate", put("s.in", b"\x01\x05\x00\x00\x00hello"), 5, TMP / "o")])
check("inflate on random bytes: a result every time, no crash", all(rc in (0, 1) for rc, o in res[:100]))
check("a stored block whose length and its complement disagree is refused (-3)", res[100][1].startswith("BAD -3"), res[100])

# ---------------------------------------------------------------- 1d. ZIP
def make_zip(entries, comment=b""):
    path = TMP / "z.zip"
    with zipfile.ZipFile(path, "w") as z:
        z.comment = comment
        for name, data, method in entries:
            z.writestr(zipfile.ZipInfo(name), data, compress_type=method, compresslevel=6 if method == zipfile.ZIP_DEFLATED else None)
    return path


exe = rnd.randbytes(5000) + b"MZ" * 40000
z = make_zip([("Readme.txt", b"hello" * 100, zipfile.ZIP_DEFLATED), ("oalinst.exe", exe, zipfile.ZIP_DEFLATED), ("stored.bin", b"abc" * 50, zipfile.ZIP_STORED)])
out = TMP / "zo"
p = ct("zipextract", z, "OALINST.EXE", out)
check("the ZIP reader finds an entry without regard to case and unpacks a deflated entry exactly", p.returncode == 0 and out.read_bytes() == exe, p.stdout)
p = ct("zipextract", z, "stored.bin", out)
check("... and a stored entry", p.returncode == 0 and out.read_bytes() == b"abc" * 50, p.stdout)
p = ct("zipfind", z, "oalinst.exe")
check("zipfind reports method, CRC and sizes", p.stdout.split()[0] == "8" and p.stdout.split()[1] == "%08x" % (zlib.crc32(exe) & 0xFFFFFFFF)
      and p.stdout.split()[3] == str(len(exe)), p.stdout)
res = batch([("zipfind", z, "missing.exe"), ("zipfind", z, "oalinst"), ("zipfind", z, "oalinst.exe ")])
check("a name that is not there is -2, a part of a name is not a match", all(o.startswith("BAD -2") for rc, o in res), res)
zc = make_zip([("oalinst.exe", exe, zipfile.ZIP_DEFLATED)], comment=b"c" * 5000)
check("a ZIP with a long comment after the central directory is found", ct("zipextract", zc, "oalinst.exe", out).returncode == 0 and out.read_bytes() == exe)
raw = bytearray(z.read_bytes())
info = zipfile.ZipFile(z).getinfo("oalinst.exe")
raw[info.header_offset + 30 + len("oalinst.exe") + 100] ^= 0x55         # damage the entry's data: the CRC must catch it
bad = put("bad.zip", bytes(raw))
p = ct("zipextract", bad, "oalinst.exe", out)
check("a damaged entry is refused (the CRC-32 or the decoder), never accepted", p.returncode != 0, p.stdout)
base = z.read_bytes()
res = batch([("zipfind", put("tz%d.zip" % cut, base[:cut]), "oalinst.exe") for cut in (0, 10, 21, 100, 5000)] + [("zipfind", put("g.zip", rnd.randbytes(3000)), "oalinst.exe")])
check("a truncated ZIP and garbage are refused (-1), nothing crashes", all(rc == 1 for rc, o in res), res)
cmds = []
for i in range(300):
    d = bytearray(base)
    for _ in range(rnd.randrange(1, 6)):
        d[rnd.randrange(len(d))] = rnd.randrange(256)
    cmds.append(("zipextract", put("fz%d.zip" % i, bytes(d)), "oalinst.exe", out))
res = batch(cmds)
check("300 ZIPs with random bytes changed: a result every time, no crash, no sanitizer report", all(rc in (0, 1) for rc, o in res))
if os.environ.get("BCD_RUNTIMES_FILES") and (Path(os.environ["BCD_RUNTIMES_FILES"]) / "oalinst.zip").is_file():
    rz = Path(os.environ["BCD_RUNTIMES_FILES"]) / "oalinst.zip"
    check("the real oalinst.zip: oalinst.exe unpacks, size and CRC-32 right", ct("zipextract", rz, "oalinst.exe", out).returncode == 0)

# ---------------------------------------------------------------- 1e. URLs and redirects
good_urls = {
    "https://download.microsoft.com/download/A/C/2/x.msi": "download.microsoft.com /download/A/C/2/x.msi",
    "https://Download.Microsoft.com/x": "download.microsoft.com /x",
    "https://www.openal.org": "www.openal.org /",
    "https://www.openal.org:443/downloads/oalinst.zip": "www.openal.org /downloads/oalinst.zip",
    "https://us.download.nvidia.com/Windows/9.21.0713/PhysX_9.21.0713_SystemSoftware.exe?x=1": "us.download.nvidia.com /Windows/9.21.0713/PhysX_9.21.0713_SystemSoftware.exe?x=1",
    "https://a.b?q=1": "a.b /?q=1",
}
res = batch([("url", u) for u in good_urls])
check("good HTTPS addresses are understood (host in lower case, default port spelled out or not, a query kept)",
      [o.strip() for rc, o in res] == list(good_urls.values()), res)
bad_urls = ["http://download.microsoft.com/x", "ftp://x.com/a", "https://user@x.com/a", "https://user:pw@x.com/a", "https://x.com:444/a", "https://x.com:80/a",
            "https://x.com:/a", "https://[::1]/a", "https://x .com/a", "https://x.com/a b", "https://x.com/a#frag", "https://x.com\\a", "https:///a", "https://.x.com/a",
            "https://-x.com/a", "https://x..com/a", "https://x_y.com/a", "https://xn--\u00e9.com/a", "//x.com/a", "x.com/a", "", "https://" + "a" * 130 + ".com/",
            "https://x.com/\x01", "https://x.com/a\x7f", "javascript:alert(1)", "HTTP://x.com/", "https://x.com:4430/a"]
res = batch([("url", u) for u in bad_urls])
check("everything else is refused: other schemes, user names, other ports, IPv6 literals, spaces and control characters, bad host names",
      all(rc == 1 for rc, o in res), [u for u, (rc, o) in zip(bad_urls, res) if rc != 1])
H = "download.microsoft.com"
BASE = "https://download.microsoft.com/download/8/4/A/file.exe"
red = {
    ("/other/f.exe", H): "download.microsoft.com /other/f.exe",
    ("//download.microsoft.com/x", H): "download.microsoft.com /x",
    ("https://download.microsoft.com/y?z=1", H): "download.microsoft.com /y?z=1",
    ("g.exe", H): "download.microsoft.com /download/8/4/A/g.exe",
    ("sub/g.exe", H): "download.microsoft.com /download/8/4/A/sub/g.exe",
}
res = batch([("redirect", BASE, loc, hosts) for (loc, hosts) in red])
check("redirects on the same host are followed: absolute, protocol-relative, absolute path, relative path", [o.strip() for rc, o in res] == list(red.values()), res)
refused = [("https://evil.example/f.exe", H), ("http://download.microsoft.com/f.exe", H), ("//evil.example/f.exe", H), ("ftp://download.microsoft.com/f", H),
           ("https://download.microsoft.com.evil.example/f", H), ("https://evil.example@download.microsoft.com/f", H), ("", H),
           ("https://download.microsoft.com:8443/f", H), ("javascript:x", H), ("https://sub.download.microsoft.com/f", H), ("mailto:a@b", H), ("file:///etc/passwd", H),
           ("HTTP://download.microsoft.com/f", H), ("https:/download.microsoft.com/f", H)]
res = batch([("redirect", BASE, loc, hosts) for (loc, hosts) in refused])
check("a redirect to another host, to HTTP, to another scheme, to a look-alike host or with a user name is refused",
      all(rc == 1 for rc, o in res), [(k, o) for k, (rc, o) in zip(refused, res) if rc != 1])
check("two allowed hosts: a redirect from one to the other is followed", ct("redirect", BASE, "https://cdn.example/x", H + ",cdn.example").stdout.strip() == "cdn.example /x")

# ---------------------------------------------------------------- small helpers
res = batch([("tenth", a, b) for a, b in ((0, 0), (5, 0), (0, 100), (9, 100), (10, 100), (99, 100), (100, 100), (150, 100), (50, 100))])
check("rt_tenth: 0 for an unknown total, whole tenths, 10 at the end", [o.strip() for rc, o in res] == ["0", "0", "0", "0", "1", "9", "10", "10", "5"], res)
res = batch([("msiok", c) for c in (0, 3010, 1641, 1638, 1603, 1618, 1, 4294967295)])
check("msiexec exit codes: 0, 3010, 1641 and 1638 are done; 1603, 1618 and 1 are failures", [o.strip() for rc, o in res] == ["1", "1", "1", "1", "0", "0", "0", "0"])
res = batch([("size", n) for n in (0, 999, 1024, 590434, 7054848, 100275120, 3 << 30)])
check("sizes read as people write them", [o.strip() for rc, o in res] == ["0 bytes", "999 bytes", "1 KB", "577 KB", "6.7 MB", "95.6 MB", "3.0 GB"], res)
res = ct("result", "xna", 1, 0, "installed").stdout.strip()
check("the result line has the id, the verdict, the text and the word 'failed' that gets it through the engine's [guest-log] mirror",
      res == "RESULT xna: PASS - installed (0 failed)" and ct("result", "dx2010", 3, 2, "x").stdout.strip() == "RESULT dx2010: FAIL - x (2 failed)", res)
names = ("d3dx9_43.dll", "XAPOFX1_0.DLL", "a-b.c.dll", "infinst.exe", "a\\b.dll", "..\\x.dll", "a/b.dll", ".dll", "x.dll.exe", "..dll", "a" * 60 + ".dll", "", "x y.dll", "x\x01.dll")
res = batch([("dllname", n) for n in names])
check("dll names: plain DLL names only", [o.strip() for rc, o in res] == ["1", "1", "1", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0"], res)
cab_cases = {"Jun2010_d3dx9_43_x86.cab": 1, "Jun2010_d3dx9_43_x64.cab": 2, "AUG2006_XACT_X64.CAB": 2, "Feb2010_XAudio_x86.cab": 1, "Apr2006_MDX1_x86.cab": 0,
             "Apr2006_MDX1_x86_Archive.cab": 0, "DSETUP.dll": 0, "DXSETUP.exe": 0, "dsetup32.dll": 0, "dxupdate.cab": 0, "dxdllreg_x86.cab": 1, "foo.cab": 0,
             "a\\b_x86.cab": 0, "../x_x64.cab": 0, "": 0, "Aug2009_d3dcsx_42_x64.cab": 2}
res = batch([("cabkind", k) for k in cab_cases])
check("cabinets of the DirectX runtime: 32-bit and 64-bit ones are read; Managed DirectX, setup files, archives and odd names are not",
      [o.strip() for rc, o in res] == [str(v) for v in cab_cases.values()], [(k, o) for k, (rc, o) in zip(cab_cases, res) if o.strip() != str(cab_cases[k])])
below = (("C:\\windows\\system32\\x.dll", "C:\\windows\\system32"), ("c:\\WINDOWS\\SYSTEM32\\x.dll", "C:\\windows\\system32"),
         ("C:\\windows\\system32", "C:\\windows\\system32"), ("C:\\windows\\system32x\\x.dll", "C:\\windows\\system32"),
         ("C:\\windows\\system32\\..\\x.dll", "C:\\windows\\system32"), ("C:\\windows\\system32\\a\\..\\..\\x.dll", "C:\\windows\\system32"),
         ("C:\\windows\\system32/x.dll", "C:\\windows\\system32"), ("C:\\windows\\syswow64\\x.dll", "C:\\windows\\system32"))
res = batch([("below", a, b) for a, b in below])
check("a path may be written only below its folder, never up and out", [o.strip() for rc, o in res] == ["1", "1", "0", "0", "0", "0", "0", "0"], res)

# ---------------------------------------------------------------- 2. the table
rows = [l.split("|") for l in ct("table").stdout.splitlines()]
want_ids = ["xna", "physx", "openal", "dx2010"]
check("the table has xna, physx, openal and dx2010, in that order", [r[0] for r in rows] == want_ids, [r[0] for r in rows])
check("every file name is a plain name; every SHA-256 is 64 lower-case hex digits; every size and space figure is positive",
      all(re.fullmatch(r"[A-Za-z0-9_.-]+", r[1]) and re.fullmatch(r"[0-9a-f]{64}", r[3]) and int(r[4]) > 0 and int(r[5]) > 0 for r in rows), rows)
check("every URL is HTTPS on a host of its own allow-list, and ends in the file name", all(r[8] == "1" and r[2].endswith("/" + r[1]) for r in rows), rows)
check("the hosts are the vendors' own: Microsoft's download server, openal.org, NVIDIA's download server",
      {r[0]: r[7] for r in rows} == {"xna": "download.microsoft.com", "physx": "us.download.nvidia.com", "openal": "www.openal.org", "dx2010": "download.microsoft.com"})
check("the pinned sizes are the sizes the vendors' servers gave on 2026-10-25",
      {r[0]: int(r[4]) for r in rows} == {"xna": 7054848, "physx": 27152680, "openal": 590434, "dx2010": 100275120})
check("the pinned SHA-256 values are the ones computed from those downloads (2026-10-25)",
      {r[0]: r[3] for r in rows} == {
          "xna": "47260420773a20443fb1e38a89b7f39c5237a80a842de598e6c8f7f90a3bbd6d",
          "physx": "26d62c5c347c15cb27c3be92bf10706113511b48b28aecc09f61ee58b3b62778",
          "openal": "d165bcb7628fd950d14847585468cc11943b2a1da92a59a839d397c68f9d4b06",
          "dx2010": "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"})
check("the kinds: XNA is an MSI (1), OpenAL a ZIP with an installer (2), PhysX the 7-Zip package (3), DirectX the cabinet reader (4)",
      {r[0]: r[6] for r in rows} == {"xna": "1", "openal": "2", "physx": "3", "dx2010": "4"}, [(r[0], r[6]) for r in rows])
smenu = (ROOT / "app" / "Madeira" / "BCDStartMenu.c").read_text()
menu_args = re.findall(r'\{ BCD_RUNTIMES, "[^"]+",\s+RUNTIMES, "[^"]+", "(\w+)" \}', smenu)
check("the Start menu has an entry for status and for every id of the table, with that id as its argument", sorted(menu_args) == sorted(want_ids + ["status"]), menu_args)

if os.environ.get("BCD_CHECK_RUNTIMES_NET") == "1":
    import urllib.request
    for r in rows:
        try:
            req = urllib.request.Request(r[2], method="HEAD")
            with urllib.request.urlopen(req, timeout=30) as resp:
                size = int(resp.headers.get("Content-Length", "-1"))
            check("%s: the vendor still serves %s bytes at the pinned address" % (r[0], r[4]), size == int(r[4]), size)
        except Exception as e:  # noqa: BLE001
            check("%s: the pinned address answers" % r[0], False, e)
else:
    print("note: BCD_CHECK_RUNTIMES_NET=1 asks each vendor's server for the pinned file's size (HEAD, no download)")
if os.environ.get("BCD_RUNTIMES_FILES"):
    for r in rows:
        f = Path(os.environ["BCD_RUNTIMES_FILES"]) / r[1]
        if f.is_file():
            check("%s: the file in BCD_RUNTIMES_FILES is the pinned one (size and SHA-256)" % r[0], f.stat().st_size == int(r[4]) and hashlib.sha256(f.read_bytes()).hexdigest() == r[3])

# ---------------------------------------------------------------- 3. path patterns on a fake disk
disk = TMP / "disk1"
gac = disk / "windows/Microsoft.NET/assembly/GAC_32"
for part in ("Microsoft.Xna.Framework", "Microsoft.Xna.Framework.Game", "Microsoft.Xna.Framework.Graphics"):
    (gac / part / "v4.0_4.0.0.0__842cf8be1de50553").mkdir(parents=True)
    (gac / part / "v4.0_4.0.0.0__842cf8be1de50553" / (part + ".dll")).write_bytes(b"MZ")
check("XNA is found when its assemblies sit in a version folder of the GAC", ct("match", disk, "id:xna").stdout.strip() == "3/3", ct("match", disk, "id:xna").stdout)
os.remove(gac / "Microsoft.Xna.Framework.Game/v4.0_4.0.0.0__842cf8be1de50553/Microsoft.Xna.Framework.Game.dll")
check("... partly when one of them is missing", ct("match", disk, "id:xna").stdout.strip() == "2/3")
shutil.rmtree(disk / "windows/Microsoft.NET")
(disk / "windows/assembly/GAC_MSIL/Microsoft.Xna.Framework/4.0.0.0__842cf8be1de50553").mkdir(parents=True)
(disk / "windows/assembly/GAC_MSIL/Microsoft.Xna.Framework/4.0.0.0__842cf8be1de50553/Microsoft.Xna.Framework.dll").write_bytes(b"MZ")
check("... and the older GAC folder counts too (one of three)", ct("match", disk, "id:xna").stdout.strip() == "1/3")
check("a pattern with a middle * names any one folder, and only one level", ct("match", disk, "C:\\windows\\assembly\\GAC_MSIL\\*\\*\\Microsoft.Xna.Framework.dll").stdout.strip() == "0"
      and ct("match", disk, "C:\\windows\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework\\*\\Microsoft.Xna.Framework.dll").stdout.strip() == "1"
      and ct("match", disk, "C:\\windows\\assembly\\GAC_MSIL\\Nope\\*\\x.dll|C:\\windows\\assembly\\GAC_MSIL\\Microsoft.Xna.Framework\\*\\Microsoft.Xna.Framework.dll").stdout.strip() == "1")
check("a folder named with a path separator or dots cannot make the matcher climb", ct("match", disk, "C:\\windows\\..\\*\\x").stdout.strip() == "0")
check("nothing installed: 0 of 3 (XNA), 0 of 3 (PhysX), 0 of 2 (OpenAL)", [ct("match", TMP / "empty-disk", "id:" + i).stdout.strip() for i in ("xna", "physx", "openal")] == ["0/3", "0/3", "0/2"])
(disk / "windows/syswow64").mkdir(parents=True)
(disk / "windows/syswow64/openal32.dll").write_bytes(b"MZ")
check("OpenAL32.dll in syswow64 only is one of two files (names are matched without regard to case)", ct("match", disk, "id:openal").stdout.strip() == "1/2")

# ---------------------------------------------------------------- 4. PhysX
plist = ct("physx-list").stdout.splitlines()
copies = [l.split("|")[1:] for l in plist if l.startswith("C|")]
regs = [l.split("|")[1:] for l in plist if l.startswith("R|")]
GOLDEN = "9aff9bc07256716dfe452258114d4df3a7cb9470169b9bd05c95eda4ed7d61b1"
check("the PhysX tables are NVIDIA's own manifest (53 files, 6 of them 64-bit; 40 registry rows, 36 values and 4 keys; a digest pinned from PhysX.nvi of the "
      "pinned download)", len(copies) == 53 and sum(c[2] == "1" for c in copies) == 6 and len(regs) == 40 and sum(r[2] == "(key only)" for r in regs) == 4
      and hashlib.sha256(("\n".join(plist) + "\n").encode()).hexdigest() == GOLDEN, (len(copies), len(regs), hashlib.sha256(("\n".join(plist) + "\n").encode()).hexdigest()))
check("every copy goes below Program Files (x86)\\NVIDIA Corporation\\PhysX, into Common or Engine, with plain relative names",
      all(re.fullmatch(r"(Common|Engine)(\\[A-Za-z0-9_.-]+)+", c[1]) and ".." not in c[0] and ".." not in c[1] for c in copies))
check("the registry rows are under SOFTWARE\\AGEIA Technologies and SOFTWARE\\NVIDIA Corporation, in the 32-bit view except eight rows of the 64-bit view",
      all(r[1].startswith(("SOFTWARE\\AGEIA Technologies", "SOFTWARE\\NVIDIA Corporation")) for r in regs) and {r[0] for r in regs} == {"32", "64"} and sum(r[0] == "64" for r in regs) == 8)

PXLOC = "Program Files (x86)/NVIDIA Corporation/PhysX"


def px_disk(name, skip=None):
    d = TMP / name
    files = d / "payload/PhysX/files"
    for i, c in enumerate(copies):
        if skip and c[0] == skip:
            continue
        p = files / c[0].replace("\\", "/")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"MZ-physx-%d-" % i + c[0].encode())
    return d


def px_run(d, is64=1, force=1, have=None):
    args = ["physx", d, is64, force] + ([have] if have is not None else [])
    p = ct(*args)
    line = next((l for l in p.stdout.splitlines() if l.startswith("result ")), "")
    res = dict(kv.split("=") for kv in line.split()[1:])
    return p, res


d = px_disk("px1")
p, res = px_run(d)
check("PhysX on a fake 64-bit Windows: 53 files copied, 36 values written, nothing failed, nothing missing, the PATH entry added",
      res == {"copied": "53", "missing": "0", "failed": "0", "newer": "0", "registry": "36", "path": "1"}, (res, p.stdout[-600:]))
ok = True
for i, c in enumerate(copies):
    f = d / PXLOC / c[1].replace("\\", "/")
    if not f.is_file() or f.read_bytes() != b"MZ-physx-%d-" % i + c[0].encode():
        ok = False
check("every file is where the manifest puts it, with the bytes of its source (the 'v2.7.x' cooking DLLs renamed from NxCooking.dll)", ok)
check("the packages's files were moved, not copied (the unpacked folder is empty of them: no second copy on the device)",
      not any((d / "payload/PhysX/files" / c[0].replace("\\", "/")).exists() for c in copies))
rlines = [l.split("|") for l in p.stdout.splitlines() if l.startswith("reg|")]
check("the registry gets the 40 rows in order, each in its view", len(rlines) == 40 and [l[1] for l in rlines] == [r[0] for r in regs], len(rlines))
named = {(l[1], l[2], l[3]): l for l in rlines}          # reg|view|key|name|type|sz|dword
AGEIA = "SOFTWARE\\AGEIA Technologies"
CORE = "C:\\Program Files (x86)\\NVIDIA Corporation\\PhysX\\Engine"
check("PhysX Version is the DWORD 9210713 in both views, HwSelection is GPU, the core path is the Engine folder",
      named[("32", AGEIA, "PhysX Version")][6] == "9210713" and named[("64", AGEIA, "PhysX Version")][6] == "9210713"
      and named[("32", AGEIA, "HwSelection")][5] == "GPU" and named[("32", AGEIA, "PhysXCore Path")][5] == CORE
      and named[("64", AGEIA, "PhysXCore Path")][5] == CORE and named[("64", AGEIA, "PhysX BuildCL")][6] == "1" and named[("32", AGEIA, "PhysX BuildCL")][6] == "0")
check("the DLL table of the update loader has an entry for each engine (and the 64-bit one in the 64-bit view)",
      sum(1 for l in rlines if "PhysXUpdateLoader\\DllTable\\" in l[2] and l[3] in ("dll_path", "dll_base_directory")) == 12
      and sum(1 for l in rlines if "351C9090" in l[2]) == 2 and all(l[1] == "64" for l in rlines if "351C9090" in l[2]))

d = px_disk("px2", skip="Engine\\v2.8.1\\NxCooking.dll")
p, res = px_run(d)
check("a file the package lacks is counted as missing and failed (the rest is installed)", res.get("missing") == "1" and res.get("failed") == "1" and res.get("copied") == "52", (res, p.stdout[-400:]))
d = px_disk("px3")
p, res = px_run(d, is64=0)
check("on a 32-bit Windows the six 64-bit files and the eight 64-bit registry rows are left out",
      res.get("copied") == "47" and not (d / PXLOC / "Common/PhysXLoader64.dll").exists() and sum(1 for l in p.stdout.splitlines() if l.startswith("reg|64")) == 0
      and sum(1 for l in p.stdout.splitlines() if l.startswith("reg|")) == 32, (res, p.stdout[-300:]))
d = px_disk("px4")
p, res = px_run(d, have=9999999)
check("a newer PhysX in the registry (version value 9999999): nothing is copied, nothing written, and it says so",
      res.get("newer") == "1" and res.get("copied") == "0" and "reg|" not in p.stdout and not (d / PXLOC).exists() and "newer PhysX is installed" in p.stdout, p.stdout[-400:])
d = px_disk("px5")
p, res = px_run(d, force=0, have=9210713)
check("the same version, without 'install again': left alone", res.get("newer") == "1" and res.get("copied") == "0" and not (d / PXLOC).exists())
d = px_disk("px6")
p, res = px_run(d, force=1, have=9210713)
check("the same version with 'install again': put in place again", res.get("copied") == "53" and res.get("newer") == "0")
d = px_disk("px7")
p, res = px_run(d, have=9000000)
check("an older PhysX (version value 9000000) is brought up to date", res.get("copied") == "53" and res.get("registry") == "36")

# ---------------------------------------------------------------- 5. the DirectX cabinet reader
def container(files):
    entries = b"".join(struct.pack("<IB", len(d), len(n)) + n.encode() for n, d in files)
    data = b"".join(d for n, d in files)
    total = 36 + len(entries) + len(data)
    head = b"MSCF" + struct.pack("<I", 0) + struct.pack("<I", total) + struct.pack("<I", 0) + struct.pack("<I", 36) + struct.pack("<I", 0) + bytes([3, 1]) + \
        struct.pack("<HH", 0, len(files)) + b"\0" * 6
    assert len(head) == 36
    return head + entries + data


def dx_fixture(name, inner_extra=None):
    inner86 = container([("d3dx9_43.dll", b"MZ-theirs-d3dx9_43-x86" * 5), ("XACTENGINE2_5.DLL", b"MZ-xact2_5-x86" * 300), ("xactengine2_1.dll", b"MZ-xact2_1-x86" * 10),
                         ("readme.txt", b"text"), ("..\\evil.dll", b"x"), ("a\\b.dll", b"y"), ("infinst.exe", b"inf"), ("d3dcsx_43.dll", b"MZ-csx-x86" * 100)])
    inner64 = container([("xactengine3_7.dll", b"MZ-xact3_7-x64" * 200), ("infinst.exe", b"inf"), ("d3dx9_43.dll", b"MZ-theirs-d3dx9_43-x64"), ("XAPOFX1_0.dll", b"MZ-xapofx-x64" * 3)])
    mdx = container([("microsoft.directx.dll", b"MZ-mdx")])
    files = [("Jun2010_d3dx9_43_x86.cab", inner86), ("Jun2010_XACT_x64.cab", inner64), ("Apr2006_MDX1_x86.cab", mdx), ("Jun2010_misc.cab", b"zz"),
             ("DXSETUP.exe", b"MZsetup"), ("dxupdate.cab", container([("dxupdate.dll", b"MZ")]))] + (inner_extra or [])
    outer = container(files)
    exe = b"MZ" + b"\0" * 300 + b"stub MSCF stub" + b"\0" * 50 + outer + b"signature bytes"
    root = TMP / name
    (root / "windows/system32").mkdir(parents=True)
    (root / "windows/syswow64").mkdir(parents=True)
    f = TMP / (name + ".exe")
    f.write_bytes(exe)
    dx_fixture.size86 = len(inner86)
    return root, f


def dx_run(root, exe, fail_after=-1):
    p = ct("dx", root, exe, fail_after)
    stats = {}
    line = next((l for l in p.stdout.splitlines() if l.startswith("rc=")), "")
    for tok in line.split():
        k, v = tok.split("=")
        stats[k] = int(v)
    added = [tuple(l.split("|")[1:]) for l in p.stdout.splitlines() if l.startswith("added|")]
    return p, stats, added


root, exe = dx_fixture("dx1")
(root / "windows/syswow64/d3dx9_43.dll").write_bytes(b"BCD-OWN-BUILTIN")
(root / "windows/system32/d3dx9_43.dll").write_bytes(b"BCD-OWN-BUILTIN-64")
p, st, added = dx_run(root, exe)
check("the cabinet inside the self-extractor is found past the stub's false 'MSCF' (at byte 366) and read to its end",
      st["rc"] == 0 and st["outer_ok"] == 1 and ct("findcab", exe).stdout.split()[0] == "366", (p.stdout[:300], ct("findcab", exe).stdout))
check("only the wanted DLLs are added: the 32-bit ones to syswow64, the 64-bit ones to system32, by the names the cabinet gives (case kept)",
      sorted(added) == sorted([("XACTENGINE2_5.DLL", "0"), ("xactengine2_1.dll", "0"), ("d3dcsx_43.dll", "0"), ("xactengine3_7.dll", "1"), ("XAPOFX1_0.dll", "1")]), added)
check("files that BCD (or an earlier run) already has keep their bytes, in both folders",
      (root / "windows/syswow64/d3dx9_43.dll").read_bytes() == b"BCD-OWN-BUILTIN" and (root / "windows/system32/d3dx9_43.dll").read_bytes() == b"BCD-OWN-BUILTIN-64"
      and st["kept"] == 2, st)
check("the added files are in the right folders with the cabinet's bytes",
      (root / "windows/syswow64/XACTENGINE2_5.DLL").read_bytes() == b"MZ-xact2_5-x86" * 300 and (root / "windows/system32/xactengine3_7.dll").read_bytes() == b"MZ-xact3_7-x64" * 200
      and (root / "windows/system32/XAPOFX1_0.dll").read_bytes() == b"MZ-xapofx-x64" * 3 and (root / "windows/syswow64/d3dcsx_43.dll").read_bytes() == b"MZ-csx-x86" * 100)
tree = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
check("nothing else was written: no part file, no .exe, no .txt, nothing with a path trick, nothing in a folder of its own",
      tree == sorted(["windows/syswow64/d3dx9_43.dll", "windows/syswow64/XACTENGINE2_5.DLL", "windows/syswow64/xactengine2_1.dll", "windows/syswow64/d3dcsx_43.dll",
                      "windows/system32/d3dx9_43.dll", "windows/system32/xactengine3_7.dll", "windows/system32/XAPOFX1_0.dll"]), tree)
check("cabinets are counted: two read, MDX1 / the odd name / DXSETUP / dxupdate skipped; files not DLLs or with path tricks skipped",
      st["cabs_read"] == 2 and st["cabs_skipped"] == 4 and st["skipped_files"] == 5 and st["failed"] == 0, st)
check("every cabinet that was opened was closed", st["opens"] == st["closes"] and st["opens"] >= 3)
p, st, added = dx_run(root, exe)
check("a second run changes nothing: no DLL added, all seven names found and kept", st["added"] == 0 and st["kept"] == 7 and st["failed"] == 0 and added == [], st)

# a copy cut short: the reader fails 2000 bytes into the 4200 bytes of XACTENGINE2_5.DLL (the first inner cabinet has been collected by then)
root, exe = dx_fixture("dx2")
p, st, added = dx_run(root, exe, fail_after=dx_fixture.size86 + 2000)
tree = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
check("a copy that stops in the middle of a DLL (the reader fails) leaves no file of that name and no part file behind",
      not any(t.endswith(".bcd-part") for t in tree) and "windows/syswow64/XACTENGINE2_5.DLL" not in tree and st["failed"] >= 1, (tree, st))
check("... and the DLLs that were already complete before it stay (none was started before it here), nothing else appears", all(t.startswith("windows/") for t in tree), tree)
# a previous run was killed: a stale part file
root, exe = dx_fixture("dx3")
(root / "windows/syswow64/xactengine2_1.dll.bcd-part").write_bytes(b"half")
p, st, added = dx_run(root, exe)
tree = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
check("a stale part file of a run that was killed is replaced, the DLL is written whole, and no part file remains",
      (root / "windows/syswow64/xactengine2_1.dll").read_bytes() == b"MZ-xact2_1-x86" * 10 and not any(t.endswith(".bcd-part") for t in tree), tree)
# a folder that cannot be written (not as root: root writes anywhere)
if os.geteuid() != 0:
    root, exe = dx_fixture("dx4")
    os.chmod(root / "windows/system32", 0o555)
    p, st, added = dx_run(root, exe)
    os.chmod(root / "windows/system32", 0o755)
    check("a folder that refuses writes: the 64-bit DLLs are counted as failed, the 32-bit ones are still added, nothing half-written",
          st["failed"] >= 2 and (root / "windows/syswow64/XACTENGINE2_5.DLL").is_file() and not list((root / "windows/system32").glob("*")), st)
else:
    print("note: running as root: the read-only folder case is skipped")
# not a cabinet
bad = TMP / "notcab.exe"
bad.write_bytes(b"MZ" + rnd.randbytes(5000))
p = ct("findcab", bad)
check("a file with no cabinet in it is not mistaken for one", p.stdout.split()[0] == "-1", p.stdout)
# a file that ends in the middle of the cabinet
root, exe = dx_fixture("dx5")
raw = exe.read_bytes()
cut = TMP / "dx5cut.exe"
cut.write_bytes(raw[:len(raw) // 2])
p = ct("dx", root, cut, -1)
check("a file that ends in the middle of the cabinet is refused before anything is written (the declared size does not fit)",
      p.stdout.startswith("BAD") and not [x for x in (root / "windows").rglob("*") if x.is_file()], p.stdout[:200])

# ---------------------------------------------------------------- 6. the program's source
prog = (SRC / "runtimes.c").read_text()
core = (SRC / "core.h").read_text()
check("every new file has the BCD licence header and a SPDX line",
      all(("SPDX-License-Identifier: GPL-3.0-only" in (SRC / f).read_text()[:200] and "BCD Material: additional terms under GPL-3.0 section 7 apply" in (SRC / f).read_text()[:400])
          for f in ("core.h", "core_test.c", "cabs.h", "fdi_host.h", "physx.h", "runtimes.c")))
check("only HTTPS is ever asked for: WinHTTP with the secure flag, redirects off and followed by hand through rt_redirect, no 'http://' address anywhere",
      "WINHTTP_FLAG_SECURE" in prog and "WINHTTP_OPTION_REDIRECT_POLICY_NEVER" in prog and "rt_redirect(" in prog and "http://" not in prog and "http://" not in core.replace("https://", ""))
check("a certificate problem is never ignored (no WINHTTP_OPTION_SECURITY_FLAGS, no SECURITY_FLAG_IGNORE)", "SECURITY_FLAGS" not in prog and "IGNORE" not in prog)
check("the size is checked against the pinned one before the first byte is kept, and the download never writes past it",
      "length != rt->size" in prog and "got + n > rt->size" in prog and "got != rt->size" in prog)
i_fetch, i_switch = prog.index("if (fetch(rt, path"), prog.index("switch (rt->kind)")
check("the SHA-256 is checked inside fetch(), which runs before anything is installed, and a mismatch deletes the file",
      i_fetch < i_switch and "rt_sha256_is(digest, rt->sha256)" in prog and "nothing was run" in prog and prog.count("DeleteFileA(part)") >= 2)
check("a file given with --file is checked just the same (size and SHA-256)", "that file is not the one BCD knows" in prog and "size != rt->size || !rt_sha256_is" in prog)
check("a DLL of the DirectX runtime is created under a part name and renamed with no replace flag (CREATE_NEW, MoveFileEx(..., 0))",
      "CREATE_NEW" in prog.split("wd_begin")[1].split("wd_write")[0] and "MoveFileExA(p->part, final_path, 0)" in prog)
check("deletions are limited: remove_tree starts with a guard that the folder is below the runtimes folder",
      re.search(r"static void remove_tree\(const char \*dir\)\s*\{[^}]*?if \(!rt_path_below\(dir, RT_DIR\)\) return;", prog, re.S) is not None
      and "FILE_ATTRIBUTE_REPARSE_POINT" in prog)
check("the program starts only: msiexec, 7-Zip, oalinst.exe (all by a full path) -- no shell, no ShellExecute, no system(), no CopyFile",
      not re.search(r"\b(ShellExecute\w*|WinExec|system\(|popen\(|CopyFile\w*|URLDownload\w*|InternetOpen\w*)", prog)
      and prog.count("CreateProcessA(") == 1 and 'SEVENZIP  SYS_DIR64 "\\\\7z.exe"' in prog)
check("a run ends with a RESULT line that holds 'failed' (rt_result_line), and stderr and the guest-log file both get every line",
      "rt_result_line(" in prog and "STD_ERROR_HANDLE" in prog and "bcd-runtimes.log" in prog and "(%d failed)" in core)
check("PhysX is installed from NVIDIA's own manifest after 7-Zip unpacked it, and the unpacked copy is removed afterwards",
      "px_install(&h, files" in prog and "remove_tree(tmp)" in prog and "BCD's 7-Zip" in prog)
check("the registry is written only by physx.h's rows and the PATH entry; nothing else in the program writes to it",
      prog.count("RegSetValueExA(") == 4 and prog.count("RegCreateKeyExA(") == 2 and "RegDeleteKey" not in prog)
check("closing the window stops a download at once and never kills an installer", "InterlockedExchange(&g_abort, 1)" in prog and "TerminateProcess" not in prog)

MING = os.environ.get("MINGW") or str(ROOT / "toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin")
if not os.path.exists(MING + "/x86_64-w64-mingw32-clang"):
    MING = os.path.expanduser("~/madeira-bcd/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin")
tracked = ROOT / "app/Madeira/arm64ec-windows/bcd-runtimes-x64.exe"
check("the program is tracked in arm64ec-windows (a session's system32)", tracked.is_file() and 40_000 < tracked.stat().st_size < 400_000)
if os.path.exists(MING + "/x86_64-w64-mingw32-clang"):
    out = TMP / "bcd-runtimes-x64.exe"
    r = subprocess.run([MING + "/x86_64-w64-mingw32-clang", "-O2", "-Wall", "-Wextra", "-Werror", "-mwindows", "-Wl,--no-insert-timestamp", "-Wl,--strip-all",
                        "-I", str(SRC), "-o", str(out), str(SRC / "runtimes.c")], capture_output=True, text=True)
    check("runtimes.c builds for Windows with -Wall -Wextra -Werror", r.returncode == 0, r.stderr[-1500:])
    if r.returncode == 0:
        check("... and the tracked program is exactly what the source builds to", out.read_bytes() == tracked.read_bytes(),
              (hashlib.sha256(out.read_bytes()).hexdigest(), hashlib.sha256(tracked.read_bytes()).hexdigest()))
    # the cabinet code against the real <fdi.h> (types, calling convention): compiled as part of runtimes.c above. The host stand-in must keep the same shapes:
    hdr = subprocess.run([MING + "/x86_64-w64-mingw32-clang", "-E", "-dM", "-x", "c", "-", "-include", "fdi.h"], input="", capture_output=True, text=True)
    check("the real fdi.h of llvm-mingw is the one runtimes.c is compiled against (DIAMONDAPI, cpuUNKNOWN, FDICreate)", "DIAMONDAPI" in hdr.stdout and "cpuUNKNOWN" in hdr.stdout, hdr.stderr[-300:])
else:
    print("note: no llvm-mingw here (MINGW=<bin dir>): the Windows build and the byte comparison with the tracked program are skipped")
if tracked.is_file():
    data = tracked.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    check("the tracked program is a 64-bit Windows GUI program (machine x86-64, subsystem 2)",
          struct.unpack_from("<H", data, pe + 4)[0] == 0x8664 and struct.unpack_from("<H", data, pe + 24 + 68)[0] == 2)
    if os.path.exists(MING + "/llvm-readobj"):
        hdr = subprocess.run([MING + "/llvm-readobj", "--file-headers", str(tracked)], capture_output=True, text=True).stdout
        check("... a plain x86-64 image, not ARM64EC", "COFF-x86-64" in hdr and "ARM64EC" not in hdr, hdr[:300])
    check("it knows the pinned values: the hosts, the SHA-256s and the Start menu argument names", all(r[3].encode() in data and r[1].encode() in data for r in rows)
          and b"download.microsoft.com" in data and b"us.download.nvidia.com" in data and b"www.openal.org" in data)

script = (ROOT / "tools" / "build-bcd-runtimes.sh").read_text()
check("the build script builds x86-64, checks the PE (imports of Windows' own DLLs, present in the farm), keeps the tracked program on failure and exits 0",
      "x86_64-w64-mingw32-clang" in script and "keeping the tracked program" in script and "exit 0" in script and "assert not bad" in script)
wf = (ROOT / ".github/workflows/build-ipa.yml").read_text()
check("the workflow checks this and builds the program after the farm", "python3 tests/host/check-bcd-runtimes.py" in wf and "bash tools/build-bcd-runtimes.sh" in wf)
gi = (ROOT / ".gitignore").read_text()
check("the build directory is ignored, the program is not", "build/bcd-runtimes/" in gi and "bcd-runtimes-x64.exe" not in gi)
short = (ROOT / "app/Madeira/licenses/THIRD-PARTY-NOTICES.txt").read_text()
check("the shipped notice says the four runtimes come from their vendors on the user's request and are never part of BCD's package",
      "BCD Runtimes" in short and "never part of BCD's packages" in short and all(v in short for v in ("XNA", "PhysX", "OpenAL", "DirectX")))

shutil.rmtree(TMP, ignore_errors=True)
print("check-bcd-runtimes: %s" % ("FAIL (%d)" % failures if failures else "PASS"))
sys.exit(1 if failures else 0)
