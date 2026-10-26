#!/bin/bash
# Builds BCD's start helper (bcd-helper/helper.c, round 604): the Windows program a game's start script calls for a delay before the game
# starts, a second program that runs beside it and window rules, with llvm-mingw:
#   bcd-helper-x64.exe  x86-64  -> app/Madeira/arm64ec-windows (the app copies it to C:\bcd-games before a start that needs it)
# The program is tracked there too, so a build without llvm-mingw, or one where this does not build, keeps the tracked file (a warning,
# not a failure: nothing depends on it unless a game's file asks for one of those things). The PE headers of what was built are checked:
# the right machine, the GUI subsystem, and imports of Windows' own DLLs only (kernel32, user32 and the C runtime's api-ms-win-crt-*),
# every one of them present in the farm when that is there. The build is reproducible (no time stamp). Run from the repository root.
set -u
R="$(pwd)"
MINGW="${MINGW:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
SRC="$R/bcd-helper"
OUT="$R/build/bcd-helper"
SHIP64="${SHIP_DIR:-$R/app/Madeira/arm64ec-windows}"
mkdir -p "$OUT"

[ -x "$MINGW/x86_64-w64-mingw32-clang" ] || { echo "::warning::build-bcd-helper: no llvm-mingw at $MINGW -- keeping the tracked runtime installer"; exit 0; }

# check_pe <file> <farm dir or "">
check_pe() {
    python3 - "$1" "$2" <<'PY'
import os, struct, sys
path, farm = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[pe:pe + 4] == b"PE\0\0", "not a PE image"
m = struct.unpack_from("<H", data, pe + 4)[0]
assert m == 0x8664, "machine %#x is not x86-64" % m
opt = pe + 24
magic = struct.unpack_from("<H", data, opt)[0]
assert magic == 0x20B, "optional header magic %#x" % magic
assert struct.unpack_from("<H", data, opt + 68)[0] == 2, "not a Windows GUI program"
nsec = struct.unpack_from("<H", data, pe + 6)[0]
secs = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
sections = [struct.unpack_from("<8sIIII", data, secs + 40 * i) for i in range(nsec)]
def rva2off(rva):
    for name, vsize, vaddr, rsize, roff in sections:
        if vaddr <= rva < vaddr + max(vsize, rsize):
            return roff + rva - vaddr
    raise AssertionError("rva %#x not in a section" % rva)
dd = opt + 112
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
ok = {"kernel32.dll", "user32.dll"}
bad = [n for n in names if n not in ok and not n.startswith("api-ms-win-crt-")]
assert not bad, "imports outside the allowed set: %s" % bad
if farm and os.path.exists(os.path.join(farm, "ntdll.dll")):
    have = {f.lower() for f in os.listdir(farm)}
    missing = [n for n in names if not n.startswith("api-ms-win-") and n not in have]
    assert not missing, "imports the farm %s does not have: %s" % (farm, missing)
PY
}

NAME=bcd-helper-x64.exe
echo "=== $NAME ==="
if "$MINGW/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -mwindows -Wl,--no-insert-timestamp -Wl,--strip-all -I"$SRC" -o "$OUT/$NAME" "$SRC/helper.c" 2> "$OUT/$NAME.err" &&
   check_pe "$OUT/$NAME" "$SHIP64" 2>> "$OUT/$NAME.err"; then
    mkdir -p "$SHIP64"
    cp "$OUT/$NAME" "$SHIP64/$NAME"
    echo "::notice::$NAME rebuilt ($(wc -c < "$OUT/$NAME" | tr -d ' ') bytes) and shipped"
else
    grep -m 20 "error\|Error\|assert" "$OUT/$NAME.err"
    echo "::warning::$NAME did not build -- keeping the tracked program"
fi
exit 0
