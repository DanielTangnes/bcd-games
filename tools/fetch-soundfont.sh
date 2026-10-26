#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
#
# Fetches the General MIDI SoundFont BCD plays MIDI music with (TimGM6mb.sf2, 5.7 MB; GPL-2.0, see
# app/Madeira/soundfont/NOTICE-TimGM6mb.txt) into app/Madeira/soundfont/, where the Xcode project's
# folder reference carries it into the app. The file is never committed (a third party's binary,
# CLAUDE.md "Do not commit externally supplied binaries"); it is downloaded, checked against the SHA-256 below
# and copied byte for byte. Two sources give the same file: the first that answers with the right bytes wins.
#
#   tools/fetch-soundfont.sh [destination folder]
#
# A copy kept in $BCD_SOUNDFONT_CACHE (default ~/madeira-local/cache/soundfont) is used when its hash is right, so
# a local build does not download it again. Without the file the app still builds and runs: there is then no MIDI
# device (the "[midi] no General MIDI sound bank found" line), which is how every earlier build behaved. Always exits 0
# unless the destination cannot be written; a warning line says what happened.
set -u
NAME=TimGM6mb.sf2
SHA256=c5378b62028c920cb11e4803327983fee2f2cdff5dc89c708e39da417e51c854
SIZE=5969788
URLS=(
  "https://raw.githubusercontent.com/musescore/musescore-old/90c33ef9d87b3f5ff92efd3b07d89eb455fb1fef/mscore/share/sound/TimGM6mb.sf2"
  "https://sources.debian.org/data/main/t/timgm6mb-soundfont/1.3-5/TimGM6mb.sf2"
)
if [ -n "${BCD_SOUNDFONT_URLS:-}" ]; then read -r -a URLS <<< "$BCD_SOUNDFONT_URLS"; fi   # the host check's hook
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$R/app/Madeira/soundfont}"
CACHE="${BCD_SOUNDFONT_CACHE:-$HOME/madeira-local/cache/soundfont}"
mkdir -p "$DEST" || { echo "::error::fetch-soundfont: cannot write $DEST"; exit 1; }

if command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; else sha() { sha256sum "$1" | cut -d' ' -f1; }; fi
host() { echo "$1" | cut -d/ -f3; }
good() { [ -f "$1" ] && [ "$(wc -c < "$1" | tr -d ' ')" = "$SIZE" ] && [ "$(sha "$1")" = "$SHA256" ]; }

if good "$DEST/$NAME"; then
  echo "soundfont :: $NAME is already in place ($SIZE bytes, SHA-256 checked)"
  exit 0
fi
rm -f "$DEST/$NAME"
if good "$CACHE/$NAME"; then
  cp "$CACHE/$NAME" "$DEST/$NAME" && echo "soundfont :: $NAME copied from the cache" && exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bcd-soundfont.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
for url in "${URLS[@]}"; do
  if curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$TMP/$NAME" "$url" 2>/dev/null && good "$TMP/$NAME"; then
    cp "$TMP/$NAME" "$DEST/$NAME" || { echo "::error::fetch-soundfont: cannot write $DEST/$NAME"; exit 1; }
    mkdir -p "$CACHE" 2>/dev/null && cp "$TMP/$NAME" "$CACHE/$NAME" 2>/dev/null
    echo "::notice::soundfont :: $NAME fetched ($SIZE bytes, SHA-256 checked) from $(host "$url")"
    exit 0
  fi
  echo "soundfont :: no usable file from $(host "$url")" >&2
done
echo "::warning::soundfont :: $NAME could not be fetched (or did not match its SHA-256): the build has no General MIDI bank, so games' MIDI music stays silent as before"
exit 0
