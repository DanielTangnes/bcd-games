#!/bin/bash
# Builds BCD's system tests (tests/systests/systest.c, the Start menu's "BCD Tests": RAM test, JIT pool test, CPU test, system info,
# VC++ and .NET check, disk speed, network test, "Run all tests") twice with llvm-mingw:
#   bcd-systest-x64.exe  x86-64   -> app/Madeira/arm64ec-windows (a session's C:\windows\system32)
#   bcd-systest-x86.exe  i686     -> app/Madeira/i386-windows    (C:\windows\syswow64), large-address-aware like a 32-bit game
# The 32-bit file is gitignored with the rest of the i386 farm except this one name, so a tracked copy is there when a build
# has no llvm-mingw or the program does not build (a warning, not a failure: the tests are diagnostics and no game depends on them).
# The PE headers of what was built are checked: the right machine, the GUI subsystem, and imports of Windows' own DLLs only
# (kernel32, user32, gdi32, advapi32 and the C runtime's api-ms-win-crt-*; everything else is loaded at run time), and the 32-bit
# file's imports must exist in the i386 farm when that is there. Run from the repository root.
set -u
R="$(pwd)"
MINGW="${MINGW:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
SRC="$R/tests/systests"
OUT="$R/build/systests"
SHIP64="${SHIP_DIR:-$R/app/Madeira/arm64ec-windows}"
SHIP32="${SHIP_DIR32:-$R/app/Madeira/i386-windows}"
mkdir -p "$OUT"

[ -x "$MINGW/x86_64-w64-mingw32-clang" ] || { echo "::warning::build-systests: no llvm-mingw at $MINGW -- keeping the tracked system tests"; exit 0; }

# check_pe <file> <machine hex> <farm dir or ""> : python does the reading
check_pe() {
    python3 - "$1" "$2" "$3" <<'PY'
import os, struct, sys
path, machine, farm = sys.argv[1], int(sys.argv[2], 16), sys.argv[3]
data = open(path, "rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe:pe + 4] == b"PE\0\0", "not a PE image"
m = struct.unpack_from("<H", data, pe + 4)[0]
assert m == machine, "machine %#x is not %#x" % (m, machine)
opt = pe + 24
magic = struct.unpack_from("<H", data, opt)[0]
assert magic == (0x20B if machine == 0x8664 else 0x10B), "optional header magic %#x" % magic
assert struct.unpack_from("<H", data, opt + 68)[0] == 2, "not a Windows GUI program"
if machine == 0x14c:
    assert struct.unpack_from("<H", data, pe + 22)[0] & 0x20, "not large-address-aware"
nsec = struct.unpack_from("<H", data, pe + 6)[0]
secs = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
sections = [struct.unpack_from("<8sIIII", data, secs + 40 * i) for i in range(nsec)]
def rva2off(rva):
    for name, vsize, vaddr, rsize, roff in sections:
        if vaddr <= rva < vaddr + max(vsize, rsize):
            return roff + rva - vaddr
    raise AssertionError("rva %#x not in a section" % rva)
dd = opt + (112 if magic == 0x20B else 96)
imp_rva = struct.unpack_from("<I", data, dd + 8)[0]
names = []
o = rva2off(imp_rva)
while True:
    f = struct.unpack_from("<IIIII", data, o)
    if f[3] == 0:
        break
    n = rva2off(f[3])
    names.append(data[n:data.index(b"\0", n)].decode().lower())
    o += 20
ok = {"kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll"}
bad = [n for n in names if n not in ok and not n.startswith("api-ms-win-crt-")]
assert not bad, "imports outside the allowed set: %s" % bad
if farm and os.path.exists(os.path.join(farm, "ntdll.dll")):
    have = {f.lower() for f in os.listdir(farm)}
    missing = [n for n in names if not n.startswith("api-ms-win-") and n not in have]
    assert not missing, "imports the farm %s does not have: %s" % (farm, missing)
PY
}

build_one() {   # <arch prefix> <name> <ship dir> <machine> <farm dir> <extra link flags...>
    local cc="$MINGW/$1-clang" name="$2" ship="$3" machine="$4" farm="$5"
    shift 5
    echo "=== $name ==="
    if [ -x "$cc" ] &&
       "$cc" -O2 -Wall -Wextra -mwindows -Wl,--no-insert-timestamp -Wl,--strip-all "$@" -I"$SRC" -o "$OUT/$name" "$SRC/systest.c" -ldxguid -luuid 2> "$OUT/$name.err" &&
       check_pe "$OUT/$name" "$machine" "$farm" 2>> "$OUT/$name.err"; then
        mkdir -p "$ship"
        cp "$OUT/$name" "$ship/$name"
        echo "::notice::$name rebuilt ($(wc -c < "$OUT/$name" | tr -d ' ') bytes) and shipped"
    else
        grep -m 20 "error\|Error\|assert" "$OUT/$name.err"
        echo "::warning::$name did not build -- keeping the tracked program"
    fi
}

build_one x86_64-w64-mingw32 bcd-systest-x64.exe "$SHIP64" 8664 ""
build_one i686-w64-mingw32 bcd-systest-x86.exe "$SHIP32" 14c "$SHIP32" -Wl,--large-address-aware
exit 0
