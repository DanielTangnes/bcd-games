#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
#
# Build FunkyFr3sh's cnc-ddraw (third-party/cnc-ddraw, MIT, tag v7.1.0.0, see BCD-SOURCE.txt there) as a 32-bit PE with llvm-mingw and ship
# it as app/Madeira/i386-windows/cnc-ddraw.dll, NEXT TO Wine's ddraw.dll, which stays the default.
#
# Why: Wine's ddraw.dll draws through wined3d. With no OpenGL it falls back to wined3d's "no3d" adapter by itself (ddraw.c: a failed
# wined3d_create is retried with WINED3D_NO3D), which keeps a 2D game's surfaces in memory but has no scaling, no borderless full screen
# and no palette-to-texture path for the display. cnc-ddraw is a ddraw.dll for old 2D games that draws the game's surfaces through its own
# renderer: Direct3D 9 (in a 32-bit session that is DXMT's, drawing through Metal), OpenGL (BCD has none) or GDI, with upscaling, a window or
# a borderless full screen. It does not do Direct3D (3D DirectDraw, Direct3D 7, is out of scope).
#
# app/Madeira/WineProcessBridge.m (BCDGraphicsRoutes.c) links cnc-ddraw.dll in as C:\windows\syswow64\ddraw.dll only when env.MADEIRA_DDRAW = cnc
# is set (the game's own file, or bcd.cfg); the farm is relinked from the bundle every session, so dropping the line restores Wine's ddraw.dll.
#
# The sources are compiled as the project's Makefile does (-O2 -std=c99, -static -shared, stdcall fixup, the same libraries) from a COPY in
# the work directory, because the build writes inc/git.h and needs two headers the tree does not carry: cnc-ddraw ships Microsoft's DirectX
# SDK ddraw.h and d3dcaps.h, which BCD does not copy (third-party/cnc-ddraw/BCD-SOURCE.txt); llvm-mingw's own are used, plus
# bcd/ddraw_dx1.h for DDCAPS_DX1 and d3dtypes.h pre-included for the Direct3D 7 emulation files (src/IDirect3D/*, IDirectDraw.c).
#
# Any failure leaves the bundle untouched (Wine's ddraw.dll ships alone), removes no file and exits 1 with a ::warning::; the workflow step
# continues on error.
#
#   CNCDDRAW_OUT=<dir>   work directory (default build/cnc-ddraw)
#   CNCDDRAW_NO_SHIP=1   build and check, but do not copy into the bundle
#   SHIP_DIR=<dir>       where the i386 farm is (default app/Madeira/i386-windows)
#   MINGW=<dir>          llvm-mingw bin directory (default: the CI toolchain)
# Run from the repository root.
set -eu
R="$(pwd)"
MINGW="${MINGW:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
SRC="$R/third-party/cnc-ddraw"
SHIP="${SHIP_DIR:-$R/app/Madeira/i386-windows}"
OUT="${CNCDDRAW_OUT:-$R/build/cnc-ddraw}"
DEST="$SHIP/cnc-ddraw.dll"
CC="$MINGW/i686-w64-mingw32-clang"
WINDRES="$MINGW/i686-w64-mingw32-windres"
READOBJ="$MINGW/llvm-readobj"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

fail() {
    echo "::warning::cnc-ddraw.dll NOT built ($*). Wine's ddraw.dll ships alone; env.MADEIRA_DDRAW = cnc has no effect in this build."
    exit 1
}

[ -x "$CC" ] || fail "no i686 clang at $CC: llvm-mingw missing"
[ -f "$SRC/src/dd.c" ] && [ -f "$SRC/exports.def" ] && [ -f "$SRC/bcd/ddraw_dx1.h" ] || fail "third-party/cnc-ddraw is not checked out"
[ -d "$SHIP" ] || fail "$SHIP does not exist"
# The vendored files are the project's, byte for byte (bcd/ is BCD's own and BCD-SOURCE.txt is the note).
(cd "$SRC" && find . -type f ! -path './bcd/*' ! -name SHA256SUMS ! -name BCD-SOURCE.txt | LC_ALL=C sort | xargs shasum -a 256 | cmp -s - SHA256SUMS) || fail "third-party/cnc-ddraw differs from SHA256SUMS"
# llvm-mingw must carry the two headers cnc-ddraw's own copies stand in for.
SYSROOT="$(dirname "$MINGW")/i686-w64-mingw32/include"
[ -f "$SYSROOT/ddraw.h" ] && [ -f "$SYSROOT/d3dcaps.h" ] && [ -f "$SYSROOT/d3dtypes.h" ] || fail "llvm-mingw has no ddraw.h, d3dcaps.h or d3dtypes.h"

rm -rf "$OUT"
mkdir -p "$OUT/obj"
cp -R "$SRC/src" "$SRC/inc" "$SRC/exports.def" "$SRC/res.rc" "$OUT/"
: > "$OUT/build.err"
# inc/git.h: what the project's Makefile writes from `git describe`; the tag instead.
printf '#define GIT_COMMIT "v7.1.0.0"\n#define GIT_BRANCH "bcd"\n' > "$OUT/inc/git.h"

CFLAGS=(-include "$SRC/bcd/ddraw_dx1.h" -I"$OUT/inc" -O2 -Wall -std=c99)
OBJ=()
running=0
for f in "$OUT"/src/*.c "$OUT"/src/*/*.c; do
    o="$OUT/obj/$(echo "${f#"$OUT"/src/}" | tr '/.' '__').o"
    OBJ+=("$o")
    extra=()
    case "$f" in */IDirect3D/*|*/IDirectDraw/IDirectDraw.c) extra=(-include d3dtypes.h) ;; esac
    ( "$CC" "${CFLAGS[@]}" "${extra[@]+"${extra[@]}"}" -c "$f" -o "$o" 2>> "$OUT/build.err" || touch "$OUT/compile.failed" ) &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
done
wait
[ ! -e "$OUT/compile.failed" ] || { grep -m 20 "error" "$OUT/build.err" || true; fail "compiling failed"; }
(cd "$OUT" && "$WINDRES" -J rc res.rc "$OUT/obj/res.o") 2>> "$OUT/build.err" || fail "windres failed"

# The project's own link line (Makefile): stdcall fixup, static, the same libraries plus dxguid (the DirectDraw IIDs: the SDK ddraw.h this tree lacks defined them in the header); file alignment 4096 like the farm's DLLs, no timestamp.
"$CC" -Wl,--enable-stdcall-fixup -Wl,--no-insert-timestamp -Wl,--file-alignment=4096 -s -static -shared -o "$OUT/cnc-ddraw.dll" \
    "${OBJ[@]}" "$OUT/obj/res.o" "$OUT/exports.def" -lgdi32 -lwinmm -lole32 -lmsimg32 -lavifil32 -luuid -ldxguid \
    2>> "$OUT/build.err" || { grep -m 20 "error\|undefined" "$OUT/build.err" || true; fail "linking failed"; }

# The result: a 32-bit image that exports the names of exports.def and imports only system and UCRT DLLs the farm has.
"$READOBJ" --file-headers "$OUT/cnc-ddraw.dll" | grep -q "IMAGE_FILE_MACHINE_I386" || fail "the result is not an i386 image"
"$READOBJ" --coff-exports "$OUT/cnc-ddraw.dll" | awk '$1 == "Name:" && $2 != "" { print $2 }' | sort -u > "$OUT/exports.built"
awk '$1 ~ /^[A-Za-z_]/ && $1 != "LIBRARY" && $1 != "EXPORTS" { print $1 }' "$OUT/exports.def" | sort -u > "$OUT/exports.expected"
# `pvBmpBits = FakePrimarySurface DATA` and `DirectInputCreateA = fake_...` export the left-hand name.
diff "$OUT/exports.expected" "$OUT/exports.built" > "$OUT/exports.diff" || { cat "$OUT/exports.diff"; fail "its exports differ from exports.def"; }
grep -qx "DirectDrawCreate" "$OUT/exports.built" && grep -qx "DirectDrawCreateEx" "$OUT/exports.built" || fail "DirectDrawCreate is not exported"
"$READOBJ" --coff-imports "$OUT/cnc-ddraw.dll" | awk '$1 == "Name:" { print tolower($2) }' | sort -u > "$OUT/imports.built"
bad="$(grep -vE '^(advapi32|avifil32|gdi32|kernel32|ole32|user32|winmm|msimg32|d3d9|opengl32)\.dll$|^api-ms-win-crt-[a-z-]+-l1-1-0\.dll$' "$OUT/imports.built" || true)"
[ -z "$bad" ] || { echo "$bad"; fail "it imports DLLs the farm would not have"; }
if grep -qE '^(d3d11|dxgi|d3d10core|d3d12|wined3d|ddraw)\.dll$' "$OUT/imports.built"; then fail "it imports another graphics DLL"; fi
if [ -f "$SHIP/kernel32.dll" ]; then
    present="$(ls "$SHIP" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r imp; do
        case "$imp" in api-ms-win-*) continue ;; esac
        echo "$present" | grep -qx "$imp" || fail "import $imp is not in the i386 farm"
    done < "$OUT/imports.built"
fi

if [ "${CNCDDRAW_NO_SHIP:-0}" = "1" ]; then
    echo "cnc-ddraw.dll built at $OUT/cnc-ddraw.dll (not shipped, CNCDDRAW_NO_SHIP=1)"
    exit 0
fi
cp "$OUT/cnc-ddraw.dll" "$DEST.tmp" && mv -f "$DEST.tmp" "$DEST" || fail "copying into the bundle failed"
echo "::notice::cnc-ddraw.dll built from FunkyFr3sh/cnc-ddraw v7.1.0.0 for i386 ($(wc -c < "$DEST" | tr -d ' ') bytes, exports = exports.def, imports system DLLs only) and shipped next to Wine's ddraw.dll, which stays the default (env.MADEIRA_DDRAW = cnc selects it)"
