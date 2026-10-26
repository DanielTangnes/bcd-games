#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""7-Zip in the Start menu (round 603): the source, the licence story and the two tracked programs.

BCD ships 7-Zip as two separate Windows programs, 7zFM.exe (the File Manager) and 7z.exe (the command line), built by
tools/build-7zip.py from the project's own release with llvm-mingw. This check proves:

  1. The source is the pinned release, byte for byte: the tracked tarball's SHA-256 is the one in third-party/7zip/SHA256SUMS, in the
     build script and in BCD-SOURCE.txt, and the licence texts BCD ships are the project's License.txt as received.
  2. The RAR code is not built. The object lists the build script reads out of 7-Zip's own nmake makefiles are evaluated (the
     makefiles do list the RAR files), and the lists it hands to the compiler hold none of them: no Archive/Rar handler, no Rar
     decoder, no Rar crypto. Every source file in the lists exists in the tarball.
  3. The tracked programs are what they should be: x86-64 PE files of the right subsystem, importing only DLLs a Wine session has
     (libc++.dll, libunwind.dll and hhctrl.ocx are NOT among them), no RAR code in them, and 7-Zip's own version text.
  4. The notices name 7-Zip and say the RAR code is left out; the workflow builds and checks it.

With BCD_CHECK_7ZIP_BUILD=1 (and an llvm-mingw, MINGW=<bin dir> or the usual place) it also builds both programs again into a
scratch folder and compares them with the tracked ones byte for byte (about ten minutes).
"""
import hashlib
import importlib.util
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
failures = 0


def check(what, ok, detail=None):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1
        if detail is not None:
            print("       " + str(detail)[:600])


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


spec = importlib.util.spec_from_file_location("build7zip", ROOT / "tools" / "build-7zip.py")
b7 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b7)

tarball = ROOT / "third-party" / "7zip" / "7z2605-src.tar.xz"
sums = (ROOT / "third-party" / "7zip" / "SHA256SUMS").read_text().split()
source_txt = (ROOT / "third-party" / "7zip" / "BCD-SOURCE.txt").read_text()
digest = sha256(tarball)

# ---------------------------------------------------------------- 1. the source
check("the tracked tarball is the pinned release (SHA256SUMS, the build script and BCD-SOURCE.txt agree on its SHA-256)",
      digest == sums[0] == b7.PINNED_SHA256 and digest in source_txt and sums[1] == "7z2605-src.tar.xz", (digest, sums))
check("BCD-SOURCE.txt names the project, the version, its tag commit and where the file came from",
      "7-Zip 26.05" in source_txt and "https://github.com/ip7z/7zip/releases/tag/26.05" in source_txt and "b88c6bc09339de32f7d18bbab900686b244f42ba" in source_txt
      and "Changes by BCD to the source: none" in source_txt)
check("the file is 1565688 bytes, as the release page lists it", tarball.stat().st_size == 1565688)

work = Path(tempfile.mkdtemp(prefix="check-7zip-"))
try:
    b7.TARBALL = str(tarball)
    src = Path(b7.unpack(str(work)))
    lic = (src / "DOC" / "License.txt").read_bytes()
    for where in ("LICENSES/7-Zip-License.txt", "app/Madeira/legal/LICENSES/7-Zip-License.txt"):
        check(where + " is the project's License.txt, byte for byte", (ROOT / where).read_bytes() == lic)
    check("the project's licence says LGPL, with the unRAR restriction for the Rar* files only",
          b"CPP/7zip/Compress/Rar* files: the \"GNU LGPL\" with \"unRAR license restriction\"" in lic and b"the \"GNU LGPL\" for all other files" in lic)

    # ------------------------------------------------------------ 2. the lists
    mk_fm = src / b7.PROGRAMS["fm"]["makefile"]
    env = b7.Env(os.path.dirname(mk_fm))
    b7.evaluate(str(mk_fm), env)
    raw_rar = re.findall(r"@O@\\(Rar\w*)\.obj", env.v.get("RAR_OBJS", "") + env.v.get("COMPRESS_OBJS", "") + env.v.get("CRYPTO_OBJS", ""))
    check("7-Zip's own makefile lists the RAR files (so leaving them out is something the build script does)",
          {"RarHandler", "Rar5Handler", "Rar1Decoder", "Rar5Decoder", "RarAes", "Rar5Aes"} <= set(raw_rar), raw_rar)
    for which in ("fm", "console"):
        lst = b7.source_list(str(src), which)
        names = [n for _, n, _ in lst]
        paths = [f for _, _, f in lst]
        check(which + ": %d sources, every one is in the tarball" % len(lst), len(lst) > 300 and all(os.path.exists(f) for f in paths),
              [f for f in paths if not os.path.exists(f)][:5])
        check(which + ": no RAR source in the list (no Archive/Rar, no Rar*Decoder, no Rar crypto)",
              not any(n.startswith("Rar") or n.startswith("Rar5") for n in names) and not any("/Archive/Rar/" in f for f in paths),
              [n for n in names if n.startswith("Rar")])
        check(which + ": no source appears twice", len(set(paths)) == len(paths))
        check(which + ": the C versions of the optimised code are in (HeapSort, AES, CRC, SHA, LzFind)",
              {"Sort", "AesOpt", "7zCrcOpt", "XzCrc64Opt", "Sha1Opt", "Sha256Opt", "LzFindOpt"} <= {n for g, n, _ in lst if g == "C_OBJS"})
        check(which + ": the formats are in (7z, zip, tar, iso, cab, wim, xz, gz, bz2 handlers)",
              {"7zHandler", "ZipHandler", "TarHandler", "IsoHandler", "CabHandler", "WimHandler", "XzHandler", "GzHandler", "Bz2Handler"} <= set(names))
    fm = [n for _, n, _ in b7.source_list(str(src), "fm")]
    con = [n for _, n, _ in b7.source_list(str(src), "console")]
    check("the File Manager list has the File Manager (FM.cpp, Panel.cpp) and the console list the console (Main.cpp)",
          {"FM", "Panel", "App"} <= set(fm) and "Main" in con and "FM" not in con)
    check("neither program asks for the Windows help engine through a source of its own (HtmlHelpW comes from tools/7zip-shim.c)",
          "HtmlHelpW" in (ROOT / "tools" / "7zip-shim.c").read_text() and b7.PROGRAMS["fm"]["shim"] and not b7.PROGRAMS["console"]["shim"])
finally:
    shutil.rmtree(work, ignore_errors=True)

# ---------------------------------------------------------------- the build script
script = (ROOT / "tools" / "build-7zip.py").read_text()
check("the build links statically (no libc++.dll to find), not as a DLL", '"-static"' in script and '"-shared"' not in script)
check("the build changes no source: it unpacks, reads the lists, compiles and links", "patch" not in script.lower().replace("path", "") and "sed -i" not in script)
check("the build checks the tarball's SHA-256 before it unpacks and keeps the tracked programs when there is no llvm-mingw",
      "PINNED_SHA256" in script and "keeping the tracked 7-Zip programs" in script)
check("tools/build-7zip.sh is the wrapper the workflow runs", (ROOT / "tools" / "build-7zip.sh").read_text().rstrip().endswith('"$@"'))
shim = (ROOT / "tools" / "7zip-shim.c").read_text()
check("the shim has the BCD licence header and defines HtmlHelpW only",
      "BCD Material: additional terms under GPL-3.0 section 7 apply" in shim and shim.count("WINAPI") == 1)
check("the build products are not committed, the two programs are (gitignore)",
      "build/7zip/" in (ROOT / ".gitignore").read_text() and "7zFM.exe" not in (ROOT / ".gitignore").read_text())

# ---------------------------------------------------------------- 3. the tracked programs
FARM = ROOT / "app" / "Madeira" / "arm64ec-windows"
for name, subsystem in (("7zFM.exe", 2), ("7z.exe", 3)):
    p = FARM / name
    check(name + " is tracked in arm64ec-windows (a session's system32)", p.is_file() and p.stat().st_size > 500_000, p)
    if not p.is_file():
        continue
    try:
        b7.check_pe(str(p), subsystem, str(FARM))
        ok, why = True, ""
    except AssertionError as e:
        ok, why = False, str(e)
    check(name + ": x86-64, subsystem %d, imports only Windows' own DLLs (every one in the farm), no RAR code" % subsystem, ok, why)
    machine, sub, names, data = b7.machine_and_imports(str(p))
    check(name + ": no libc++.dll, libunwind.dll or hhctrl.ocx among the imports",
          not {"libc++.dll", "libunwind.dll", "hhctrl.ocx", "libstdc++-6.dll"} & set(names), names)
    check(name + ": 7-Zip 26.05, the licence text of the project is in it",
          b"26.05" in data or "26.05".encode("utf-16le") in data, None)
    check(name + ": built without the unRAR code (no Rar decoder class names, no unRAR text)",
          b"NRar" not in data and b"unRAR" not in data and b"RarHandler" not in data and b"Rar5Handler" not in data)
_ming = os.environ.get("MINGW") or str(ROOT / "toolchains" / "llvm-mingw-20260421-ucrt-macos-universal" / "bin")
if not os.path.exists(_ming + "/llvm-readobj"):
    _ming = os.path.expanduser("~/madeira-bcd/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin")
if os.path.exists(_ming + "/llvm-readobj"):
    for name in ("7zFM.exe", "7z.exe"):
        hdr = subprocess.run([_ming + "/llvm-readobj", "--file-headers", str(FARM / name)], capture_output=True, text=True).stdout
        check(name + " is a plain x86-64 image, not an ARM64EC one (an ARM64EC program is an experiment: ARCH=arm64ec)", "COFF-x86-64" in hdr and "ARM64EC" not in hdr, hdr[:300])
else:
    print("note: no llvm-readobj (MINGW=<bin dir>): x86-64 versus ARM64EC was not told apart (both have machine 0x8664)")
check("7zFM.exe carries the common-controls manifest (visual styles) and the English strings", b"Microsoft.Windows.Common-Controls" in (FARM / "7zFM.exe").read_bytes())

# ---------------------------------------------------------------- 4. notices and workflow
notices = (ROOT / "THIRD-PARTY-NOTICES.md").read_text()
short = (ROOT / "app" / "Madeira" / "licenses" / "THIRD-PARTY-NOTICES.txt").read_text()
check("THIRD-PARTY-NOTICES.md has a 7-Zip row: version, licences, the RAR code left out, the source and its SHA-256",
      "**7-Zip** 26.05" in notices and "unRAR" in notices and "not built" in notices and b7.PINNED_SHA256 in notices and "tools/build-7zip.py" in notices)
check("the shipped short notice names 7-Zip, the RAR exclusion and where the source is",
      "7-Zip 26.05" in short and "WITHOUT its" in short and "third-party/7zip" in short)
check("the bundled copy of the notices is the repository's", notices == (ROOT / "app" / "Madeira" / "legal" / "THIRD-PARTY-NOTICES.md").read_text())
check("the MinGW-w64 runtime notice (statically linked) is bundled", (ROOT / "app/Madeira/legal/LICENSES/MinGW-w64-runtime.txt").is_file()
      and (ROOT / "LICENSES/MinGW-w64-runtime.txt").read_bytes() == (ROOT / "app/Madeira/legal/LICENSES/MinGW-w64-runtime.txt").read_bytes())
wf = (ROOT / ".github" / "workflows" / "build-ipa.yml").read_text()
check("the workflow checks this and builds 7-Zip after the farm (a failure keeps the tracked programs)",
      "python3 tests/host/check-7zip.py" in wf and "bash tools/build-7zip.sh" in wf)

# ---------------------------------------------------------------- optional: rebuild and compare
if os.environ.get("BCD_CHECK_7ZIP_BUILD") == "1":
    ming = os.environ.get("MINGW", str(ROOT / "toolchains" / "llvm-mingw-20260421-ucrt-macos-universal" / "bin"))
    if not os.path.exists(ming + "/x86_64-w64-mingw32-clang++"):
        ming = os.path.expanduser("~/madeira-bcd/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin")
    scratch = Path(tempfile.mkdtemp(prefix="check-7zip-build-"))
    try:
        env2 = dict(os.environ, MINGW=ming, WORK=str(scratch / "work"), SHIP_DIR=str(scratch / "ship"))
        r = subprocess.run([sys.executable, str(ROOT / "tools" / "build-7zip.py")], env=env2, capture_output=True, text=True)
        check("the build runs again and ships both programs", r.returncode == 0 and (scratch / "ship" / "7zFM.exe").is_file() and (scratch / "ship" / "7z.exe").is_file(),
              r.stdout[-600:] + r.stderr[-600:])
        for name in ("7zFM.exe", "7z.exe"):
            a, b = scratch / "ship" / name, FARM / name
            check(name + ": a new build is byte for byte the tracked program", a.is_file() and a.read_bytes() == b.read_bytes(),
                  (sha256(a) if a.is_file() else None, sha256(b)))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
else:
    print("note: BCD_CHECK_7ZIP_BUILD=1 builds both programs again and compares them with the tracked ones")

print("check-7zip: %s" % ("FAIL (%d)" % failures if failures else "PASS"))
sys.exit(1 if failures else 0)
