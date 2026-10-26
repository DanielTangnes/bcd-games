#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
#
# Build crosire's d3d8to9 (third-party/d3d8to9, BSD 2-Clause, tag v1.16.0, see BCD-SOURCE.txt there) as a 32-bit PE with llvm-mingw
# and ship it as app/Madeira/i386-windows/d3d8to9.dll, NEXT TO Wine's d3d8.dll, which stays the default.
#
# Why: a Direct3D 8 program loads C:\windows\syswow64\d3d8.dll, Wine's, which draws through wined3d's OpenGL backend, and BCD has no
# OpenGL: Direct3DCreate8 returns NULL ("wined3d_adapter_gl_init Failed to get a GL context") and the game stops (GTA III, POSTAL 2, Hotline
# Miami, Max Payne 2's renderer). d3d8to9 is a d3d8.dll that implements Direct3D 8 on top of Direct3D 9 (it calls Direct3DCreate9 and
# translates the device, the resources, the state and the fixed-function and 1.x shader paths); in a 32-bit session d3d9.dll is DXMT's
# shim (d3d9-emulated.dll), so the chain is Direct3D 8 -> d3d9 -> DXMT -> Metal. It needs d3dx9_43.dll (Wine's, in the i386 farm) at run
# time for D3DXAssembleShader and D3DXLoadSurfaceFromSurface.
#
# app/Madeira/WineProcessBridge.m links d3d8to9.dll in as C:\windows\syswow64\d3d8.dll only when env.MADEIRA_D3D8 = d3d9 is set (the game's
# own file, or bcd.cfg); the farm is relinked from the bundle every session, so dropping the line restores Wine's d3d8.dll at the next start.
# The sources are compiled as the project's Release configuration does (-DD3D8TO9NOLOG: no d3d8.log file next to the game, no message box
# on a missing log); nothing in the sources is changed.
#
# Any failure leaves the bundle untouched (Wine's d3d8.dll ships alone), removes no file and exits 1 with a ::warning::; the workflow step
# continues on error.
#
#   D3D8TO9_OUT=<dir>    work directory (default build/d3d8to9)
#   D3D8TO9_NO_SHIP=1    build and check, but do not copy into the bundle
#   SHIP_DIR=<dir>       where the i386 farm is (default app/Madeira/i386-windows)
#   MINGW=<dir>          llvm-mingw bin directory (default: the CI toolchain)
# Run from the repository root.
set -eu
R="$(pwd)"
MINGW="${MINGW:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
SRC="$R/third-party/d3d8to9"
SHIP="${SHIP_DIR:-$R/app/Madeira/i386-windows}"
OUT="${D3D8TO9_OUT:-$R/build/d3d8to9}"
DEST="$SHIP/d3d8to9.dll"
CXX="$MINGW/i686-w64-mingw32-clang++"
WINDRES="$MINGW/i686-w64-mingw32-windres"
READOBJ="$MINGW/llvm-readobj"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

fail() {
    echo "::warning::d3d8to9.dll NOT built ($*). Wine's d3d8.dll ships alone; env.MADEIRA_D3D8 = d3d9 has no effect in this build."
    exit 1
}

[ -x "$CXX" ] || fail "no i686 clang++ at $CXX: llvm-mingw missing"
[ -f "$SRC/source/d3d8to9.cpp" ] && [ -f "$SRC/res/d3d8.def" ] || fail "third-party/d3d8to9 is not checked out"
[ -d "$SHIP" ] || fail "$SHIP does not exist"
# The vendored files are the project's, byte for byte.
(cd "$SRC" && find . -type f ! -name SHA256SUMS ! -name BCD-SOURCE.txt | LC_ALL=C sort | xargs shasum -a 256 | cmp -s - SHA256SUMS) || fail "third-party/d3d8to9 differs from SHA256SUMS"

rm -rf "$OUT"
mkdir -p "$OUT/obj"
: > "$OUT/build.err"

# One compile per source file, $JOBS at a time.
CXXFLAGS=(-std=c++17 -O2 -DD3D8TO9NOLOG -Wall -Wno-delete-non-virtual-dtor -Wno-unknown-pragmas)
OBJ=()
running=0
for f in "$SRC"/source/*.cpp; do
    o="$OUT/obj/$(basename "$f" .cpp).o"
    OBJ+=("$o")
    ( "$CXX" "${CXXFLAGS[@]}" -c "$f" -o "$o" 2>> "$OUT/build.err" || touch "$OUT/compile.failed" ) &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
done
wait
[ ! -e "$OUT/compile.failed" ] || { grep -m 20 "error" "$OUT/build.err" || true; fail "compiling failed"; }
"$WINDRES" -I "$SRC/res" "$SRC/res/d3d8to9.rc" -O coff -o "$OUT/obj/d3d8to9_rc.o" 2>> "$OUT/build.err" || fail "windres failed"

# The project's own link (CMakeLists.txt): the module definition file, stdcall fixup, d3d9; plus gdi32 (GetDeviceCaps), which MSVC links
# by default. File alignment 4096 like every DLL of the i386 farm; libc++ and the compiler runtime are static, the C runtime comes through
# api-ms-win-crt-* (the same UCRT every 32-bit DLL of the farm uses).
"$CXX" -shared -o "$OUT/d3d8to9.dll" "${OBJ[@]}" "$OUT/obj/d3d8to9_rc.o" "$SRC/res/d3d8.def" \
    -static-libgcc -static-libstdc++ -Wl,--enable-stdcall-fixup -Wl,--no-insert-timestamp -Wl,--file-alignment=4096 \
    -ld3d9 -lgdi32 2>> "$OUT/build.err" || { grep -m 20 "error\|undefined" "$OUT/build.err" || true; fail "linking failed"; }
"$MINGW/i686-w64-mingw32-strip" --strip-debug "$OUT/d3d8to9.dll" || fail "strip failed"

# The result: a 32-bit image, exporting exactly the four functions of d3d8.def, importing only d3d9 and the system and UCRT DLLs.
"$READOBJ" --file-headers "$OUT/d3d8to9.dll" | grep -q "IMAGE_FILE_MACHINE_I386" || fail "the result is not an i386 image"
"$READOBJ" --coff-exports "$OUT/d3d8to9.dll" | awk '$1 == "Name:" && $2 != "" { print $2 }' | sort -u > "$OUT/exports.built"
awk 'NR > 1 && $1 != "" { print $1 }' "$SRC/res/d3d8.def" | sort -u > "$OUT/exports.expected"
diff "$OUT/exports.expected" "$OUT/exports.built" > "$OUT/exports.diff" || { cat "$OUT/exports.diff"; fail "its exports differ from res/d3d8.def"; }
"$READOBJ" --coff-imports "$OUT/d3d8to9.dll" | awk '$1 == "Name:" { print tolower($2) }' | sort -u > "$OUT/imports.built"
grep -qx "d3d9.dll" "$OUT/imports.built" || fail "it does not import d3d9.dll"
bad="$(grep -vE '^(d3d9|gdi32|kernel32|shell32|user32)\.dll$|^api-ms-win-crt-[a-z-]+-l1-1-0\.dll$' "$OUT/imports.built" || true)"
[ -z "$bad" ] || { echo "$bad"; fail "it imports DLLs the farm would not have"; }
# With the farm at hand (CI), every import must be in it, the way build/wine-i386/build.sh checks its own modules.
if [ -f "$SHIP/kernel32.dll" ]; then
    present="$(ls "$SHIP" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r imp; do
        case "$imp" in api-ms-win-*) continue ;; esac
        echo "$present" | grep -qx "$imp" || fail "import $imp is not in the i386 farm"
    done < "$OUT/imports.built"
    for dep in d3d9.dll d3dx9_43.dll; do
        echo "$present" | grep -qx "$dep" || fail "$dep (needed at run time) is not in the i386 farm"
    done
fi

if [ "${D3D8TO9_NO_SHIP:-0}" = "1" ]; then
    echo "d3d8to9.dll built at $OUT/d3d8to9.dll (not shipped, D3D8TO9_NO_SHIP=1)"
    exit 0
fi
cp "$OUT/d3d8to9.dll" "$DEST.tmp" && mv -f "$DEST.tmp" "$DEST" || fail "copying into the bundle failed"
echo "::notice::d3d8to9.dll built from crosire/d3d8to9 v1.16.0 for i386 ($(wc -c < "$DEST" | tr -d ' ') bytes, exports = d3d8.def, imports d3d9.dll and system DLLs only) and shipped next to Wine's d3d8.dll, which stays the default (env.MADEIRA_D3D8 = d3d9 selects it)"
