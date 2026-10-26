# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""What round 604's input checks share: a counter of passes and failures, a way to read code without its comments, to cut a
function out of a source file, to compile and run a Swift behaviour harness on the host, and to build the preview app.

check-bcd-radial.py and check-bcd-touch-extras.py import it. (The first three of the round, check-bcd-turbo.py, check-bcd-touch-look.py
and check-bcd-players.py, were written before it and carry their own copies.)"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
HEADER = ("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)\n"
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.\n")
PY_HEADER = "#!/usr/bin/env python3\n# SPDX-License-Identifier: GPL-3.0-only\n# Copyright 2026 thebcd69 (BCD)\n"


class Checks:
    def __init__(self, args):
        self.failures = 0
        self.args = args

    def check(self, cond, what, detail=""):
        print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)[-2500:]) if detail and not cond else ""))
        if not cond:
            self.failures += 1

    def licence(self, names_and_texts, script):
        for name, text in names_and_texts:
            self.check(text.startswith(HEADER), f"{name}: BCD's licence header")
        self.check(Path(script).read_text().startswith(PY_HEADER), "this check: BCD's licence header")

    def harness(self, label, files, harness_name):
        """Compiles the Swift harness as main.swift together with `files` (names under app/Madeira) and runs it."""
        swiftc = shutil.which("swiftc")
        if not swiftc:
            self.check(not self.args.require_swift, f"swiftc for the {label} behaviour checks", "not found")
            return
        with tempfile.TemporaryDirectory(prefix="bcd-input-") as tmp:
            main = Path(tmp) / "main.swift"
            main.write_text((R / "tests/host" / harness_name).read_text())
            exe = Path(tmp) / "check"
            r = subprocess.run([swiftc, "-O"] + [str(APP / n) for n in files] + [str(main), "-o", str(exe)], capture_output=True, text=True)
            self.check(r.returncode == 0, f"the {label} behaviour checks compile on the host", r.stderr or r.stdout)
            if r.returncode == 0:
                r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
                for line in r.stdout.splitlines():
                    if line.startswith("FAIL") or line.startswith("ALL"):
                        print("  " + line)
                self.check(r.returncode == 0, f"{label} behaves as described", r.stdout + r.stderr)

    def preview(self, what):
        if self.args.skip_preview:
            print("SKIP: the preview build (--skip-preview)")
        elif not shutil.which("xcrun"):
            self.check(not self.args.require_swift, "xcrun for the preview build", "not found")
        else:
            with tempfile.TemporaryDirectory(prefix="bcd-input-preview-") as tmp:
                r = subprocess.run([sys.executable, str(R / "tools/ui-preview.py"), "--build-only", "--out", tmp], capture_output=True, text=True)
                self.check(r.returncode == 0, f"the preview build compiles ({what})", r.stderr or r.stdout)

    def finish(self, name):
        if self.failures:
            print(f"{self.failures} FAILED")
            sys.exit(1)
        print("PASS: " + name)


def code(text):
    """The text without comments, so a word in a comment counts for nothing."""
    out = []
    for line in text.splitlines():
        if line.strip().startswith("//"):
            continue
        out.append(re.sub(r'\s//[^"]*$', "", line))
    return "\n".join(out)


def func(text, header):
    """A function (or type) from its header to its closing brace."""
    p = text.index(header)
    a = text.index("{", p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == "{") - (text[b] == "}")
        b += 1
    return text[p:b]


def imports(text):
    return re.findall(r"^import (\w+)", code(text), re.M)
