#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""The video test's synthetic source (tools/gen-video-test-clips.sh): 30 frames of 160x96 at 15 fps as raw BGRA and 2.0 s of a 440 Hz
mono tone at 44100 Hz as raw s16le. Every number here is also in tests/dxtests/bcdstats.h (BT_CLIP_*), which the video test
measures the decoded clip against:
  - a progress bar along the bottom 8 rows: white on near black, (frame + 1) * 160 / 30 pixels long;
  - a white 16x16 square that moves;
  - a red left half and a blue right half, darker towards the bottom.
usage: genframes.py <out dir>"""
import math
import struct
import sys
from pathlib import Path

W, H, N, FPS, RATE = 160, 96, 30, 15, 44100
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)


def frame(i):
    rows = []
    sx = int((W - 16) * (i / (N - 1)))
    sy = int((H - 40) * abs(math.sin(i * 0.35))) + 8
    bar = int((i + 1) * W / N)
    for y in range(H):
        row = bytearray()
        for x in range(W):
            if y >= H - 8:
                v = 255 if x < bar else 24
                b = g = r = v
            elif sy <= y < sy + 16 and sx <= x < sx + 16:
                b = g = r = 255
            else:
                k = 1.0 - 0.5 * y / H
                if x < W // 2:
                    r, g, b = int(200 * k), int(40 * k), int(40 * k)
                else:
                    r, g, b = int(40 * k), int(40 * k), int(200 * k)
            row += bytes((b, g, r, 255))
        rows.append(bytes(row))
    return b"".join(rows)


with open(out / "frames.bgra", "wb") as f:
    for i in range(N):
        f.write(frame(i))
with open(out / "tone.pcm", "wb") as f:
    total = RATE * N // FPS
    for n in range(total):
        fade = min(1.0, n / (0.01 * RATE), (total - n) / (0.01 * RATE))
        f.write(struct.pack("<h", int(32767 * 0.5 * fade * math.sin(2 * math.pi * 440 * n / RATE))))
print("frames %dx%d x%d at %d fps, tone %d Hz sample rate, %d samples" % (W, H, N, FPS, RATE, RATE * N // FPS))
