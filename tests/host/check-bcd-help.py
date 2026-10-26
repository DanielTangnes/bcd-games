#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Help with a game (round 604): the guided debug run (D5), game feedback through the Feedback intake (D7) and the launch check (D6).

Behaviour (swiftc; --require-swift makes its absence a failure):
  - BCDHelpCore.swift, BCDGameHelp.swift, BCDReadinessCore.swift and BCDGraphicsScan.swift compiled with the page's rules and
    tests/host/bcd_help_checks.swift: the run's phases and lifetimes, the question's words, the feedback message (machine-readable first
    line, the numbers a message may repeat, the intake's 4000 characters), the section's rows and their locks, and the readiness rules;
  - the readiness scan on synthetic folders of real PE images (32- and 64-bit, imports and delay imports): MFC, Mono, OpenAL, PhysX, DirectX 2010;
    a redistributable folder is not read, a symbolic link is not followed;
  - tools/pull-logs.py reads the message the app writes.

Source (every host):
  1. A run sends nothing by itself: the log goes only from the "Send log" button of its question, through the comment box and LogUpload.send;
     the detailed log and the trace are asked for by the session and put back; the saved setting is never written.
  2. Feedback goes through the existing intake (FeedbackUpload.send, kind "other"), not a new route: the Worker is unchanged. The player sees the
     whole message before it goes.
  3. The launch check changes nothing and blocks nothing: a note on the page, read once per folder change on a utility queue.
  4. The hooks are the ones listed; CI runs this check.

  check-bcd-help.py [--require-swift]
"""
import argparse
import importlib.util
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
ap = argparse.ArgumentParser()
ap.add_argument("--require-swift", action="store_true")
args = ap.parse_args()
failures = 0


def check(cond, what, detail=""):
    global failures
    print(("PASS: " if cond else "FAIL: ") + what + (("\n      " + str(detail)) if detail and not cond else ""))
    if not cond:
        failures += 1


def code(text):
    out = []
    for line in text.splitlines():
        if line.strip().startswith("//"):
            continue
        out.append(re.sub(r'\s//[^"]*$', "", line))
    return "\n".join(out)


def block(text, header):
    p = text.index(header)
    a = text.index("{", p)
    n, b = 1, a + 1
    while n:
        n += (text[b] == "{") - (text[b] == "}")
        b += 1
    return text[p:b]


HEADER = ("// SPDX-License-Identifier: GPL-3.0-only\n// Copyright 2026 thebcd69 (BCD)\n"
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.\n")
FILES = ["BCDHelpCore.swift", "BCDGameHelp.swift", "BCDReadinessCore.swift", "BCDReadinessLive.swift", "BCDHelpLive.swift", "BCDGamePageLiveHelp.swift"]
texts = {f: (APP / f).read_text() for f in FILES}
pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
workflow = (R / ".github/workflows/build-ipa.yml").read_text()
preview = (R / "tools/ui-preview.py").read_text()
page = (APP / "BCDGamePage.swift").read_text()
page_live = (APP / "BCDGamePageLive.swift").read_text()
recorder_text = (APP / "BCDSessionRecorderLive.swift").read_text()

# ---- 1. licence, layering, project -------------------------------------------------------------------------------
for f in FILES:
    check(texts[f].startswith(HEADER), f"{f}: BCD's licence header")
    check(pbx.count(f"/* {f} in Sources */") == 2 and pbx.count(f"path = {f};") == 1, f"the Xcode project builds {f}")
for f in ("BCDHelpCore.swift", "BCDGameHelp.swift", "BCDReadinessCore.swift"):
    c = code(texts[f])
    check(re.findall(r"^import (\w+)", c, re.M) == ["Foundation"] and not re.search(r"\b(LibraryModel|LogStore|MadeiraConfig|madeira_|UIKit|SwiftUI|UserDefaults\.standard)\b", c),
          f"{f}: Foundation only, no engine type (the preview app builds it)")
for f in ("BCDReadinessLive.swift", "BCDHelpLive.swift", "BCDGamePageLiveHelp.swift"):
    check(re.search(r'ENGINE_BOUND \|= \{[^}]*"%s"' % re.escape(f), preview) is not None, f"the preview app leaves {f} out")
check("python3 tests/host/check-bcd-help.py" in workflow, "CI runs this check")
check(not re.search(r"(?i)auto-?tune", "".join(code(t) for t in texts.values())), "the new files name no auto-tune")
check("DateFormatter" not in "".join(texts.values()) and "ISO8601" not in "".join(texts.values()) and ".formatted(" not in "".join(texts.values()),
      "no date is made with an ICU formatter (it killed BCD in three logs)")

# ---- 2. the debug run -------------------------------------------------------------------------------------------
live = code(texts["BCDHelpLive.swift"])
run_cls = block(live, "@MainActor final class BCDDebugRunLive {")
began = block(run_cls, "func sessionBegan(_ entry: LibraryEntry) {")
check("guard var current = run, current.phase == .armed else { return }" in began and "guard current.matches(entryID: entry.id.uuidString, steamAppID: entry.steamAppID) else { return }" in began,
      "only an armed run of this game's entry becomes the session's run: any other game's start is untouched")
check("BCDPerfTraceLive.guidedRun = true" in began and "if !InputSettings.shared.diagnostics { madeira_set_diag_enabled(1); diagnosticsForced = true }" in began,
      "the trace is asked for and the detailed log turned on only for the run, and only if it was off")
check("diagnostics = " not in run_cls and "InputSettings.shared.diagnostics =" not in live, "the saved 'Detailed logs' setting is never written")
ended = block(run_cls, "func sessionEnded() {")
check("BCDPerfTraceLive.guidedRun = false" in ended and "madeira_set_diag_enabled(InputSettings.shared.diagnostics ? 1 : 0)" in ended and "diagnosticsForced = false" in ended,
      "the session's end puts the trace request and the detailed log back to what the player chose")
check("LogUpload.send" not in run_cls and "FeedbackUpload" not in run_cls, "the run itself sends nothing")
prompt = block(live, "@MainActor final class BCDDebugRunPrompt {")
look = block(prompt, "private func look() {")
check("if tries > 100 || library.current != nil { drop(); return }" in look and "library.error == nil" in look and "library.restartNotice == nil" in look
      and "UIApplication.shared.applicationState == .active" in look and "BCDCrashPrompt.presenter()" in look,
      "the question waits for a free screen, is dropped when a game starts or after five minutes, and never takes a screen away")
present = block(prompt, "private func present(on top: UIViewController) {")
check(present.count("LogUpload.send(") == 1 and 'title: "Send log"' in present and "BCDLogComment.prefill = BCDDebugRules.comment(for: run)" in present and "BCDLogComment.ask(for: log, {" in present,
      "the log goes only from 'Send log', through the comment box that starts with the player's notes")
check("BCDDebugRunLive.shared.finish()" in present and "self.run = nil" in present, "one question per run: it is spent when shown")
app_started = block(run_cls, "func appStarted() {")
check("BCDDebugRules.offerable(current, appJustStarted: true" in app_started and "coversUnfinished = current.phase == .running" in app_started,
      "a run that was open when BCD closed is asked about once, and covers the crash question of the same session")
recover = block(code(recorder_text), "func recoverUnfinished() {")
check("if BCDDebugRunLive.shared.coversUnfinished { return }" in recover and recover.index("try? FileManager.default.removeItem(at: url)") < recover.index("coversUnfinished"),
      "the crash question leaves that session alone (the marker is still removed first)")
rec = code(recorder_text)
check(rec.count("BCDDebugRunLive.shared.sessionBegan(entry)") == 1 and rec.index("BCDDebugRunLive.shared.sessionBegan(entry)") < rec.index("BCDPerfTraceLive.shared.began()"),
      "the run is told before the trace starts (the trace reads its request)")
check(rec.count("BCDDebugRunLive.shared.sessionEnded()") == 1 and rec.count("BCDDebugRunLive.shared.appStarted()") == 1 and
      rec.index("BCDDebugRunLive.shared.appStarted()") < rec.index("BCDSessionRecorderLive.shared.recoverUnfinished()"),
      "the run hears the session end, and the app start before the crash question")
comp = (APP / "BCDComponents.swift").read_text()
check("static var prefill = \"\"" in comp and "field.text = starting.isEmpty ? nil : starting" in comp and "prefill = \"\"" in comp, "the comment box can start with words (taken by the next box only)")

# ---- 3. the page --------------------------------------------------------------------------------------------------
pl = code(texts["BCDGamePageLiveHelp.swift"])
check(page_live.count("helpGroup(game, entry)") == 1 and page_live.count("helpSet(setting, to: value, for: game)") == 1 and "if !desktop { d.groups.append(helpGroup(game, entry)) }" in page_live,
      "the page's two hooks: the group (not for the Wine desktop) and the setting")
start = block(pl, "private func helpStartRun(_ game: BCDGame) {")
check("BCDDebugRunLive.shared.arm(run)" in start and "onNotice?()" in start and "BCDLiveStore.shared.play(game)" in start
      and start.index("arm(run)") < start.index("onNotice?()") < start.index("play(game)"), "Start a debug run arms it, closes the page, then starts the game as Play does")
send = block(pl, "private func helpSendFeedback(_ game: BCDGame) {")
check('FeedbackUpload.send(kind: "other", text: text, log: log)' in send and send.count("FeedbackUpload.send(") == 1,
      "feedback goes through the existing intake, kind 'other'")
check("static func send(kind: String, text: String, log: String? = nil" in code((APP / "FeedbackUpload.swift").read_text()) and "feedback/" in (R / "bcd-logs/worker/worker.js").read_text(), "... which exists as it was (the Worker is unchanged)")
check(send.count("LogUpload.send(") == 1 and "guard draft.attachLog else { return post(log: nil) }" in send, "the log goes first only when the player ticked it")
check("kind: \"other\"" in pl and "FEEDBACK_KINDS = [\"bug\", \"idea\", \"other\"]" in (R / "bcd-logs/worker/worker.js").read_text(), "'other' is a kind the intake takes")
numbers = block(pl, "enum BCDHelpNumbers {")
check("tailBytes: Int = 512 * 1024" in numbers and "BCDSessionSummary.fields(" in numbers, "the numbers come from the tail of the log's own [session] line")
check("var readiness: String? = nil" in page and "if let readiness = details.readiness { notes.append(Note(text: readiness, warning: true)) }" in page
      and "d.readiness = BCDReadinessLive.shared.note(for: entry)" in page_live, "the launch check is a note on the page: it blocks nothing")

# ---- 4. the launch check ----------------------------------------------------------------------------------------
rl = code(texts["BCDReadinessLive.swift"])
check("DispatchQueue.global(qos: .utility).async" in rl and "BCDReadiness.scan(root)" in rl and "guard !running.contains(root.path) else { return nil }" in rl,
      "the scan runs once per folder on a utility queue")
check(not re.search(r"\b(write|createFile|removeItem|moveItem|setenv|copyItem)\b", rl), "the live side writes nothing and sets no environment")
core = code(texts["BCDReadinessCore.swift"])
check(not re.search(r"\b(write|createFile|removeItem|moveItem|copyItem|createDirectory)\(", core) and "skipDescendants()" in core and "isSymbolicLink == true" in core,
      "the scan reads only, never follows a symbolic link, and skips redistributable folders")

# ---- behaviour --------------------------------------------------------------------------------------------------
swiftc = shutil.which("swiftc")


def pe(machine, imports=(), delay=()):
    """A PE image whose import tables name `imports` and `delay` (tests/host/check-d3d9-x64-default.py's builder)."""
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
    body += names
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
if not swiftc:
    check(not args.require_swift, "swiftc on the host (behaviour checks)")
else:
    with tempfile.TemporaryDirectory(prefix="bcd-help-") as t:
        t = Path(t)
        src = t / "src"
        src.mkdir()
        page_text = page
        start_at = page_text.index("// MARK: - The page's rules")
        end_at = page_text.index("// MARK: - Opening the page")
        (src / "Rules.swift").write_text("import Combine\nimport Foundation\nimport SwiftUI\n\n" + page_text[start_at:end_at])
        for n in ("BCDStore.swift", "BCDGameDLC.swift", "BCDHelpCore.swift", "BCDGameHelp.swift", "BCDReadinessCore.swift", "BCDGraphicsScan.swift"):
            shutil.copy(APP / n, src / n)
        shutil.copy(R / "tests/host/bcd_help_checks.swift", src / "Harness.swift")
        exe = t / "help"
        b = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-o", str(exe)] + sorted(str(p) for p in src.glob("*.swift")),
                           capture_output=True, text=True)
        check(b.returncode == 0, "the help rules, the section and the launch check compile on the host with the page's rules", b.stderr[-2500:])
        if b.returncode == 0:
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            oks = [l for l in r.stdout.splitlines() if l.startswith("ok")]
            bad = [l for l in r.stdout.splitlines() if l.startswith("FAIL") or l.startswith("     ")]
            check(r.returncode == 0 and len(oks) >= 50, f"help rules: {len(oks)} checks", "\n      ".join(bad[:14]))
            note = next((l[len("note: "):] for l in r.stdout.splitlines() if l.startswith("note: [game-feedback]")), "").replace(" ¶ ", "\n")

            def scan(folder, *flags):
                out = subprocess.run([str(exe), "scan", str(folder), *flags], capture_output=True, text=True, timeout=60).stdout
                return out.splitlines()

            # a game folder of real PE images
            g = t / "game"
            (g / "bin").mkdir(parents=True)
            (g / "game.exe").write_bytes(pe(X64, imports=["kernel32.dll", "d3d11.dll"]))
            (g / "bin" / "tool.dll").write_bytes(pe(X64, imports=["kernel32.dll", "MFC140U.dll"]))
            lines = scan(g)
            check(lines[0].startswith("modules=2 ") and lines[1] == "findings=mfc64", "a 64-bit DLL two levels in that imports mfc140u.dll: MFC is missing", str(lines))
            check(scan(g, "vc")[1] == "findings=", "... and Microsoft's Visual C++ runtime is enough", str(scan(g, "vc")))
            (g / "mfc140u.dll").write_bytes(pe(X64, imports=["kernel32.dll"]))
            check(scan(g)[1] == "findings=", "... and so is a copy the game carries itself", str(scan(g)))
            h = t / "old"
            h.mkdir()
            (h / "old.exe").write_bytes(pe(X86, imports=["kernel32.dll", "openal32.dll", "xactengine2_1.dll"], delay=["physxloader.dll"]))
            check(scan(h)[1] == "findings=openal,physx,dx2010", "a 32-bit program's imports and delay imports: OpenAL, PhysX, an older DirectX file", str(scan(h)))
            check(scan(h, "openal", "physx", "dx")[1] == "findings=", "... each gone once its runtime is installed", str(scan(h, "openal", "physx", "dx")))
            m = t / "net"
            m.mkdir()
            (m / "g.exe").write_bytes(pe(X86, imports=["mscoree.dll"]))
            (m / "Microsoft.Xna.Framework.dll").write_bytes(b"MZ-not-a-pe")
            check(scan(m)[1] == "findings=mono,xna" and scan(m, "mono", "xna")[1] == "findings=", ".NET without Wine Mono, and XNA named by the folder", str(scan(m)))
            r2 = t / "redist"
            (r2 / "_CommonRedist" / "vcredist").mkdir(parents=True)
            (r2 / "g.exe").write_bytes(pe(X64, imports=["kernel32.dll"]))
            (r2 / "_CommonRedist" / "vcredist" / "setup.exe").write_bytes(pe(X86, imports=["mfc140u.dll", "mscoree.dll"]))
            check(scan(r2)[1] == "findings=" and scan(r2)[0].startswith("modules=1 "), "a redistributable folder is not read (an installer's imports are not the game's)", str(scan(r2)))
            s = t / "links"
            s.mkdir()
            outside = t / "outside"
            outside.mkdir()
            (outside / "x.dll").write_bytes(pe(X64, imports=["mfc140u.dll"]))
            os.symlink(outside, s / "link")
            (s / "g.exe").write_bytes(pe(X64, imports=["kernel32.dll"]))
            check(scan(s)[1] == "findings=" and scan(s)[0].startswith("modules=1 "), "a symbolic link is not followed", str(scan(s)))
            e = t / "empty"
            e.mkdir()
            (e / "readme.txt").write_text("hello")
            check(scan(e) == ["modules=0 files=1 complete=true", "findings="], "a folder with no program file has nothing to say", str(scan(e)))

            # tools/pull-logs.py reads the message the app writes
            spec = importlib.util.spec_from_file_location("pull_logs", R / "tools/pull-logs.py")
            pl_mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(pl_mod)
            summary = pl_mod.game_feedback_summary(note) if note else None
            check(summary is not None and summary.startswith("Hollow Knight: runs, small problems (slow, sound)") and "avg=58.7" in summary and "low1=41.2" in summary,
                  "tools/pull-logs.py --feedback shows the message the app writes in one line", str(summary))
            check(pl_mod.game_feedback_summary("hello there") is None and pl_mod.game_feedback_summary("[game-feedback] result=fine") is None,
                  "... and shows anything else as it did")

print("PASS: help with a game" if failures == 0 else f"FAILED: help with a game ({failures})")
sys.exit(1 if failures else 0)
