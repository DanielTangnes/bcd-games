// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host check for a game fix's `redist` reader (app/Madeira/BCDGameSetup/BCDGameFixRedist.swift), compiled with BCDCab.c and the
// production zip reader by tests/host/check-game-setup.py. argv[1] is a folder with the test files that script made:
//   plain.cab (stored): Docs/readme.txt, Bin\xinput1_3.dll    nested.exe: junk, then a cabinet holding dx.cab, which holds d3dx9_43.dll
//   archive.zip: sub/xinput1_3.dll, a.txt                       lzx.cab: a cabinet whose folder says LZX      empty.bin: no cabinet
// Prints "ok" / "FAIL" lines.

import Foundation

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    checks += 1
    if !ok { failures += 1 }
    print((ok ? "ok   " : "FAIL ") + what + (ok || detail.isEmpty ? "" : "\n     " + detail))
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func dll(_ tag: UInt8) -> Data { var d = Data([0x4D, 0x5A]); d.append(Data(repeating: tag, count: 3000)); return d }

func attempt(_ file: String, _ member: String) -> (Data?, String) {
    do { return (try BCDGameFixRedist.extract(from: dir.appendingPathComponent(file), member: member), "") }
    catch { return (nil, error.localizedDescription) }
}

do {
    let (a, _) = attempt("plain.cab", "xinput1_3.dll")
    check(a == dll(1), "a DLL is read out of a cabinet, found by its name without the folder")
    let (b, _) = attempt("plain.cab", "XINPUT1_3.DLL")
    check(b == dll(1), "in any case")
    let (c, why) = attempt("plain.cab", "nothere.dll")
    check(c == nil && why.contains("not in"), "a member that is not there fails", why)
    let (d, _) = attempt("nested.exe", "d3dx9_43.dll")
    check(d == dll(2), "a cabinet inside a cabinet inside a program is searched")
    let (e, _) = attempt("archive.zip", "xinput1_3.dll")
    check(e == dll(3), "a DLL is read out of a zip")
    let (f, why2) = attempt("lzx.cab", "xinput1_3.dll")
    check(f == nil && why2.contains("LZX"), "an LZX cabinet is refused, with the reason", why2)
    let (g, why3) = attempt("empty.bin", "xinput1_3.dll")
    check(g == nil && why3.contains("not in"), "a file with no cabinet fails", why3)
    let (h, why4) = attempt("missing.cab", "x.dll")
    check(h == nil && !why4.isEmpty, "a missing file fails", why4)
}

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
