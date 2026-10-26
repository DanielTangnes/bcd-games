#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""DXMT's Direct3D 9 as the default for a 64-bit Direct3D 9 game whose folder shows no Direct3D 11, DXGI or Direct3D 12 (round 602).

BCDGraphicsScan.swift (the very file the app compiles) is built with swiftc and run on synthetic game folders made here: real PE
files with import tables (static and delay-load, 32 and 64 bit) and with names only in the text (ASCII and UTF-16, across a chunk edge).
What has to hold, because the owner's rule is that nothing that works today changes:
  - a folder with a program that imports d3d11, dxgi or d3d12 (static or delay-load), or whose text names them (LoadLibrary), in any
    sub-folder, is "unchanged": Unity and Unreal games, Direct3D 11 and 12 games, a launcher with Chromium (libcef.dll) included;
  - a scan that cannot finish (a file larger than the limit, too many entries) is "unchanged", never "dxmt";
  - "dxmt" needs a 64-bit program that shows Direct3D 9 (imports d3d9.dll, or names it) and nothing modern anywhere; a 32-bit Direct3D 9
    game (it has DXMT's i386 d3d9 already) and a folder with no Direct3D at all are "unchanged";
  - the hook is one line in LibraryEntry.applyEnvironment, after the game's own lines were applied; the game's own word wins; a master
    switch turns the default off; the decision is logged; nothing else in the app names the key.
Run from the repository root; needs swiftc on PATH.
"""
from pathlib import Path
import json
import os
import re
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
ok = True


def check(what, cond):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)


# --- a minimal PE with an import table ------------------------------------------------------------------------------
def pe(machine, imports=(), delay=(), text=b"", pad=0):
    pe64 = machine in (0x8664, 0xaa64)
    opt = 240 if pe64 else 224
    base = 0x1000
    imp_len = (len(imports) + 1) * 20
    del_len = (len(delay) + 1) * 32
    names_off = imp_len + del_len
    names, rvas = b"", []
    for d in list(imports) + list(delay):
        rvas.append(base + names_off + len(names))
        names += d.encode() + b"\0"
    body = bytearray(imp_len + del_len)
    for i in range(len(imports)):
        struct.pack_into("<IIIII", body, i * 20, 0, 0, 0, rvas[i], 0)
    for i in range(len(delay)):
        struct.pack_into("<II", body, imp_len + i * 32, 1, rvas[len(imports) + i])
    body += names + text + b"\0" * pad
    raw = (len(body) + 0x1ff) & ~0x1ff
    body += b"\0" * (raw - len(body))
    hdr = bytearray(0x400)
    hdr[0:2] = b"MZ"
    struct.pack_into("<I", hdr, 60, 0x80)
    o = 0x80
    hdr[o:o + 4] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", hdr, o + 4, machine, 1, 0, 0, 0, opt, 0x2102)
    oo = o + 24
    struct.pack_into("<H", hdr, oo, 0x20b if pe64 else 0x10b)
    if pe64:
        struct.pack_into("<Q", hdr, oo + 24, 0x140000000)
    else:
        struct.pack_into("<I", hdr, oo + 28, 0x400000)
    struct.pack_into("<II", hdr, oo + 32, 0x1000, 0x200)
    struct.pack_into("<II", hdr, oo + 56, 0x1000 + raw, 0x400)
    ndir = oo + (108 if pe64 else 92)
    struct.pack_into("<I", hdr, ndir, 16)
    dd = oo + (112 if pe64 else 96)
    if imports:
        struct.pack_into("<II", hdr, dd + 8, base, imp_len)
    if delay:
        struct.pack_into("<II", hdr, dd + 13 * 8, base + imp_len, del_len)
    sec = oo + opt
    hdr[sec:sec + 8] = b".idata\0\0"
    struct.pack_into("<IIIIIIHHI", hdr, sec + 8, len(body), base, raw, 0x400, 0, 0, 0, 0, 0x40000040)
    return bytes(hdr) + bytes(body)


X64, X86 = 0x8664, 0x14c
wide = lambda s: s.encode("utf-16-le")

# --- the program under test ---------------------------------------------------------------------------------------
swift = r'''
import Foundation
let args = CommandLine.arguments
var limits = BCDGraphicsScan.Limits()
var i = 2
while i + 1 < args.count {
    switch args[i] {
    case "--per-file": limits.perFileBytes = Int(args[i + 1])!
    case "--entries": limits.entries = Int(args[i + 1])!
    case "--total": limits.totalBytes = Int(args[i + 1])!
    default: break
    }
    i += 2
}
if args[1] == "--root-of" {
    // installationRoot: argv[2] = program, argv[3] = the folder above which nothing is the game's
    let program = URL(fileURLWithPath: args[2])
    let top = URL(fileURLWithPath: args[3])
    print(BCDGraphicsScan.installationRoot(of: program, inside: { $0.path.hasPrefix(top.path) }, stopAt: { $0.path == top.path }).path)
    exit(0)
}
let r = BCDGraphicsScan.scan(URL(fileURLWithPath: args[1]), limits: limits)
let d = BCDGraphicsScan.decide(r)
let out: [String: Any] = ["dxmt": d.dxmt, "why": d.why, "images": r.imagesRead, "complete": r.complete, "modern": r.modern ?? "", "web": r.webEngine ?? "",
                          "x64": r.d3d9x64 ?? "", "x86": r.d3d9x86 ?? ""]
print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / "main.swift").write_text(swift)
    exe = tmp / "scan-check"
    src = root / "app/Madeira/BCDGraphicsScan.swift"
    r = subprocess.run(["swiftc", "-O", "-o", str(exe), str(src), str(tmp / "main.swift")], capture_output=True, text=True)
    check("BCDGraphicsScan.swift compiles with swiftc on its own (pure Foundation)", r.returncode == 0)
    if r.returncode:
        print(r.stderr[-3000:])
        sys.exit(1)

    n = 0

    def game(files, **opts):
        """Builds a folder of {relative path: bytes (or ("link", target))}; returns the scan's answer."""
        global n
        n += 1
        d = tmp / f"g{n}"
        for rel, data in files.items():
            p = d / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(data, tuple) and data[0] == "link":
                os.symlink(data[1], p)
            else:
                p.write_bytes(data)
        d.mkdir(exist_ok=True)
        args = [str(exe), str(d)]
        for k, v in opts.items():
            args += ["--" + k.replace("_", "-"), str(v)]
        out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
        return json.loads(out.strip().splitlines()[-1])

    plain = pe(X64, ["kernel32.dll", "user32.dll"])

    # --- what flips -------------------------------------------------------------------------------------------------
    a = game({"Game.exe": pe(X64, ["kernel32.dll", "D3D9.dll"])})
    check("a 64-bit program that imports d3d9.dll and nothing modern: DXMT", a["dxmt"] and a["images"] == 1 and "imports d3d9.dll" in a["x64"], )
    a = game({"bin/x64/Game.exe": pe(X64, ["kernel32.dll"], text=b"..Direct3DCreate9.."), "Data/readme.txt": b"d3d11.dll"})
    check("a 64-bit program whose text names Direct3DCreate9 (LoadLibrary) and nothing modern: DXMT (a text file is not a program)", a["dxmt"] and "names d3d9" in a["x64"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"]), "plugins/Helper.dll": pe(X64, ["kernel32.dll"], text=wide("d3d9.dll"))})
    check("UTF-16 text is read too (a name in a helper DLL), and a second Direct3D 9 file changes nothing", a["dxmt"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"]), "_CommonRedist/DirectX/Jun2010/DXSETUP.exe": pe(X86, ["kernel32.dll"], text=b"d3d11.dll dxgi.dll")})
    check("a redistributable folder (_CommonRedist\\DirectX) is not the game: its DXSETUP.exe naming d3d11 does not count", a["dxmt"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"]), "Mods": ("link", str(tmp))})
    check("a symbolic link is not followed (a link to a folder is not part of the game)", a["dxmt"] and a["images"] == 1)

    # --- what never flips: Direct3D 11, DXGI and Direct3D 12 ----------------------------------------------------------
    for name, files in {
        "static d3d11.dll": {"Game.exe": pe(X64, ["d3d9.dll", "d3d11.dll"])},
        "static dxgi.dll": {"Game.exe": pe(X64, ["D3D9.DLL", "DXGI.dll"])},
        "static d3d12.dll": {"Game.exe": pe(X64, ["d3d12.dll"]), "Old.exe": pe(X64, ["d3d9.dll"])},
        "delay-load d3d11.dll": {"Game.exe": pe(X64, ["d3d9.dll"], delay=["d3d11.dll"])},
        "an import in a sub-folder": {"Game.exe": pe(X64, ["d3d9.dll"]), "Engine/Binaries/Win64/Render.dll": pe(X64, ["dxgi.dll"])},
        "a 32-bit helper that imports d3d11": {"Game.exe": pe(X64, ["d3d9.dll"]), "Tools/Launcher.exe": pe(X86, ["d3d11.dll"])},
    }.items():
        a = game(files)
        check(f"{name}: unchanged", not a["dxmt"] and a["modern"])
    a = game({"Game.exe": pe(X64, ["UnityPlayer.dll"]), "UnityPlayer.dll": pe(X64, ["d3d9.dll"], text=b"xx d3d11.dll xx")})
    check("Unity: UnityPlayer.dll loads d3d11.dll by name (no import): unchanged", not a["dxmt"] and "names d3d11" in a["modern"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], text=wide("DXGI.DLL"))})
    check("a name in UTF-16 text (Unreal modules): unchanged", not a["dxmt"] and "names dxgi" in a["modern"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], text=b"..D3D11CreateDevice..")})
    check("GetProcAddress names (D3D11CreateDevice): unchanged", not a["dxmt"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], text=b".CreateDXGIFactory1.")})
    check("CreateDXGIFactory: unchanged", not a["dxmt"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], text=b".D3D12CreateDevice.")})
    check("D3D12CreateDevice: unchanged", not a["dxmt"])
    # a name cut by the 4 MB chunk edge
    cut = b"\0" * (4 * 1024 * 1024 - 0x400 - 0x200 - 4) + b"D3D11.dll"
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], text=cut)})
    check("a name straddling the 4 MB read chunk is still found: unchanged", not a["dxmt"])
    cut = wide("d3d11.dll")
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], text=b"\0" * (4 * 1024 * 1024 - 0x600 - 5) + cut)})
    check("a UTF-16 name straddling the chunk edge is still found: unchanged", not a["dxmt"])
    for web in ("libcef.dll", "LibGLESv2.dll", "chrome_elf.dll"):
        a = game({"Launcher.exe": pe(X64, ["d3d9.dll"]), "bin/" + web: pe(X64, ["kernel32.dll"])})
        check(f"a web engine ({web}) in the folder: unchanged", not a["dxmt"] and a["web"] == web.lower())

    # --- what never flips: no 64-bit Direct3D 9, or unsure -----------------------------------------------------------------
    a = game({"Game.exe": pe(X86, ["d3d9.dll"])})
    check("a 32-bit Direct3D 9 game (DXMT's i386 d3d9 serves it already): unchanged", not a["dxmt"] and "only 32-bit" in a["why"])
    a = game({"Game.exe": plain})
    check("a program with no Direct3D at all: unchanged", not a["dxmt"] and "no program shows Direct3D 9" in a["why"])
    a = game({"Game.exe": b"MZ not really a program", "readme.txt": b"d3d9.dll"})
    check("no readable program file: unchanged", not a["dxmt"] and a["images"] == 0)
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], pad=3 * 1024 * 1024)}, per_file=1024 * 1024)
    check("a file larger than the per-file limit makes the scan unsure: unchanged", not a["dxmt"] and not a["complete"] and "not sure" in a["why"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"], pad=1024 * 1024), "Other.dll": pe(X64, ["kernel32.dll"], pad=1024 * 1024)}, total=1024 * 1024)
    check("more bytes than the total limit: unchanged", not a["dxmt"] and not a["complete"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"]), **{f"data/f{i}.bin": b"x" for i in range(40)}}, entries=20)
    check("more directory entries than the limit: unchanged", not a["dxmt"] and not a["complete"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll", "d3d11.dll"]), **{f"data/f{i}.bin": b"x" for i in range(40)}}, entries=20)
    check("a Direct3D 11 program beside the root ends the scan before the walk: unchanged because of Direct3D 11, not 'not sure'", not a["dxmt"] and a["complete"] and "imports d3d11.dll" in a["modern"])
    a = game({"Game.exe": pe(X64, ["d3d9.dll"]), "Engine.dll": pe(X64, ["kernel32.dll"], text=b"D3D11.DLL")})
    check("the text pass looks at every program, not only the one that imports d3d9: unchanged", not a["dxmt"])

    # --- the installation root --------------------------------------------------------------------------------------
    top = tmp / "drive"
    (top / "Games/Foo/bin/x64").mkdir(parents=True)
    root_of = lambda prog: subprocess.run([str(exe), "--root-of", str(prog), str(top)], capture_output=True, text=True, check=True).stdout.strip()
    check("Foo/bin/x64/Foo.exe: the installation root is Foo (conventional binary folders are climbed)", root_of(top / "Games/Foo/bin/x64/Foo.exe").endswith("Games/Foo"))
    (top / "Games/Bar").mkdir(parents=True)
    check("Games/Bar/Bar.exe: the program's own folder (Games is never climbed into)", root_of(top / "Games/Bar/Bar.exe").endswith("Games/Bar"))
    (top / "Games/bin").mkdir(parents=True)
    check("Games/bin/Baz.exe stops at Games (a shared folder is not an installation)", root_of(top / "Games/bin/Baz.exe").endswith("Games/bin"))

# --- the wiring ---------------------------------------------------------------------------------------------------------
lib = (root / "app/Madeira/Library.swift").read_text()
glue = (root / "app/Madeira/BCDGraphicsDefaults.swift").read_text()
scan_src = (root / "app/Madeira/BCDGraphicsScan.swift").read_text()
env = lib[lib.index("    func applyEnvironment() {"):]
env = env[:env.index("    /// What the bridge starts.")]
check("LibraryEntry.applyEnvironment calls the default once, after the game's own lines were applied (applyGame) and before the profile line",
      env.count("BCDGraphicsDefaults.applyD3D9X64(for: self)") == 1
      and env.index("try MadeiraConfig.applyGame(gameConfigText)") < env.index("BCDGraphicsDefaults.applyD3D9X64(for: self)") < env.index('fputs("[frontend] launch profile applied'))
check("Library.swift holds nothing else of it: one call, no scan, no setenv of the key",
      lib.count("BCDGraphicsDefaults.applyD3D9X64") == 1 and "BCDGraphicsScan" not in lib and 'setenv("MADEIRA_D3D9_X64"' not in lib)
# Round 602 review: a remembered answer (check-d3d9-x64-cache.py) exports the same value without a new scan; it was a scan's answer too.
_sets = [m.start() for m in re.finditer(r'(?<!un)setenv\(d3d9X64Key, "dxmt", 1\)', glue)]
check("the default is exported only as the value dxmt, and only after the scan said so (now or at an earlier start: the remembered answer)",
      len(re.findall(r"(?<!un)setenv\(", glue)) == 2 and len(_sets) == 2
      and glue.index("if let cached = cachedDecision(") < _sets[0] < glue.index("let (dxmt, why) = BCDGraphicsScan.decide(result)")
      < glue.index("remember(root, signature: signature") < _sets[1])
check("the game's own word wins: bcd.cfg, the entry's lines, the profile file and the process environment are asked first",
      all(w in glue for w in ("MadeiraConfig.get(key)", "MadeiraConfig.parse(entry.gameConfigText", "MadeiraConfig.gameValue(key)", "getenv(d3d9X64Key)"))
      and glue.index("MadeiraConfig.gameValue(key)") < glue.index("BCDGraphicsScan.scan(root)"))
check("a library entry already known as Direct3D 11 or 12 (its program's imports) is left alone without a scan",
      'known.contains("D3D11") || known.contains("D3D12")' in glue and glue.index('known.contains("D3D11")') < glue.index("BCDGraphicsScan.scan(root)"))
check("env.BCD_D3D9_X64_AUTO = 0 turns it off for every game", 'static let d3d9X64AutoKey = "BCD_D3D9_X64_AUTO"' in glue and "guard MadeiraConfig.flag(d3d9X64AutoKey)" in glue)
check("a value this file set is removed again at the next call (no session inherits it)", "if setHere { unsetenv(d3d9X64Key); setHere = false }" in glue)
check("the decision is logged in both directions with the reason",
      "[d3d9-x64] default=dxmt because" in glue and "[d3d9-x64] default unchanged (Wine's d3d9.dll):" in glue)
check("it never looks at the Desktop entry, a batch file or a folder that is a drive or a system folder",
      "entry.desktop != true, !entry.isBatch" in glue and "url.path != drive.path" in glue and '"program files"' in glue and '"windows"' in glue)
check("the scan reads and never writes (no write, remove, move, create in BCDGraphicsScan.swift)",
      not re.search(r"\.write\(|removeItem|moveItem|createFile|createDirectory|setenv|unsetenv", scan_src))
check("the bridge is untouched: it still links d3d9-dxmt.dll only for the value dxmt (the existing block)",
      (root / "app/Madeira/WineProcessBridge.m").read_text().count('getenv("MADEIRA_D3D9_X64")') == 1)

# --- auto-tune: the three games whose own program fails the probe (their lists carry the line too, tests/host/check-d3d9-x64.py) ------------
import importlib.util
spec = importlib.util.spec_from_file_location("autotune_rules", root / "build/tools/autotune_rules.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
rule = next(r for r in mod.RULES if r["id"] == "d3d9-64bit-dxmt-games")
fx = root / "tests/fixtures/autotune"


def signal_hits(text, sig):
    return sum(1 for l in text.split("\n") if all(h in l for h in sig["has"])) >= sig.get("count", 1)


def rule_matches(r, text):
    return (all(signal_hits(text, x) for x in r.get("all", [])) and (not r.get("any") or any(signal_hits(text, x) for x in r["any"]))
            and not any(signal_hits(text, x) for x in r.get("none", [])))


check("rule d3d9-64bit-dxmt-games adds the one line after the GL failure and the failed probe, for three games only, once, and not after the bridge's link line or in a 32-bit session",
      rule["lines"] == ["env.MADEIRA_D3D9_X64 = dxmt"] and rule.get("noRetry") and len(rule["any"]) == 9
      and {"has": ["wined3d_adapter_gl_init Failed to get a GL context"]} in rule["all"] and {"has": ["Direct3DCreate9 called -> d3d9_init FAILED"]} in rule["all"]
      and {"has": ["MADEIRA_D3D9_X64=dxmt: d3d9.dll -> d3d9-dxmt.dll"]} in rule["none"] and {"has": ["[wow-window]"]} in rule["none"] and {"has": ["wow64cpu"]} in rule["none"])
for name, outcome in (("pico-park-d3d9-64bit-2026-10-20", "crashed"), ("dont-starve-together-d3d9-64bit-2026-10-19", "crashed"), ("a-hat-in-time-d3d9-64bit-2026-10-17", "exited-early")):
    expect = json.loads((fx / (name + ".expect")).read_text())
    log = (fx / (name + ".log")).read_text()
    check(f"{name}: the fixture proposes the line ({outcome})", expect["matched"] == ["d3d9-64bit-dxmt-games"] and expect["next"] == ["env.MADEIRA_D3D9_X64 = dxmt"] and expect["outcome"] == outcome)
    check(f"{name}: not after the link line, not in a 32-bit session, not without the failed probe, not for another game",
          rule_matches(rule, log) and not rule_matches(rule, log + "\n[WineProc] MADEIRA_D3D9_X64=dxmt: d3d9.dll -> d3d9-dxmt.dll (x)\n")
          and not rule_matches(rule, log + "\n[wow-window] session armed\n") and not rule_matches(rule, log.replace("d3d9_init FAILED", "ok"))
          and not rule_matches(rule, re.sub(r"library launch [^:\n]*:|\[session-log\] Steam game [^:\n]*:|Session log: logs/[^ \n]*", "library launch Some Other Game:", log)))
    check(f"{name}: scrubbed", not re.search(r"/var/mobile/Containers|/Users/(?!<user>)|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}", log))
fires = sorted(p.name[:-7] for p in fx.glob("*.expect") if "d3d9-64bit-dxmt-games" in json.loads(p.read_text()).get("matched", []))
check("no other fixture matches it: %s" % fires, fires == ["a-hat-in-time-d3d9-64bit-2026-10-17", "dont-starve-together-d3d9-64bit-2026-10-19", "pico-park-d3d9-64bit-2026-10-20"])

print("PASS: 64-bit Direct3D 9 by default through DXMT" if ok else "FAILED")
sys.exit(0 if ok else 1)
