#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
"""Game setup (round 604): Windows version, components, CPU translation presets, game fixes, Wine desktop.
app/Madeira/BCDGameSetup/, BCDGameSetupRules.swift, BCDGameSetupTables.swift, BCDGameSetupPage.swift.

Never starts a game and never touches the real prefix. Part A reads the sources and pins the promises: the hooks are one line each,
nothing runs for a game whose file has none of the lines, no fix can write or take a program, the registry is edited only before
the wineserver exists, the files are in the Xcode project. Part B compiles the rules, the registry editor and the fix runner on this
Mac with DockReset.swift (the .reg editor they extend) and runs them on the template's real user.reg and system.reg and a prefix built
in a scratch folder. Part C compiles the sections' words and rows with the page's rules. Part D compiles the redistributable reader
with BCDCab.c and the production zip reader and runs it on cabinets this script builds (stored, nested in a program, LZX).
Run with python3; --require-swift fails when xcrun swiftc is missing (the macOS build runner).
"""
import argparse
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
APP = R / "app/Madeira"
SETUP = APP / "BCDGameSetup"
HEADER = ["// SPDX-License-Identifier: GPL-3.0-only",
          "// Copyright 2026 thebcd69 (BCD)",
          "// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md."]
ap = argparse.ArgumentParser()
ap.add_argument("--require-swift", action="store_true")
args = ap.parse_args()
ok = True


def check(what, cond, detail=""):
    global ok
    print(("ok   " if cond else "FAIL ") + what + ("" if cond or not detail else "\n     " + str(detail)))
    ok &= bool(cond)


def read(path):
    return Path(path).read_text(encoding="utf-8")


def code(text):
    """The source without comments and string contents, for 'names no X' checks."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r'"(?:[^"\\]|\\.)*"', '""', line.split("//")[0]) for line in text.split("\n"))


# ------------------------------------------------------------------------------ Part A: the sources
top = [APP / "BCDGameSetupRules.swift", APP / "BCDGameSetupTables.swift", APP / "BCDGameSetupPage.swift"]
engine = [SETUP / n for n in ("BCDRegistryEdit.swift", "BCDGameFixRun.swift", "BCDGameFixRedist.swift", "BCDGameSetupLaunch.swift", "BCDGamePageLiveSetup.swift", "BCDExeIcon.swift", "BCDSaveRedirect.swift", "BCDPrefixKit.swift")]
project = read(R / "app/Madeira.xcodeproj/project.pbxproj")
for f in top + engine:
    check(f"{f.name}: BCD's licence header, exactly", read(f).split("\n")[:3] == HEADER)
    rel = f.relative_to(APP).as_posix()
    check(f"{f.name}: built by the Xcode project (build file, reference and group entry)",
          project.count(f"/* {rel} in Sources */") == 2 and project.count(f"/* {f.name} */") >= 3, rel)
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', read(f))
    check(f"{f.name}: no \"Madeira\" in a string it shows or logs", not [x for x in literals if "madeira" in x.lower() and not x.startswith("env.MADEIRA_")])
    check(f"{f.name}: never names the external drive", "ssd" not in code(read(f)).lower() and "external" not in code(read(f)).lower())

rules, tables, page = (read(f) for f in top)
registry, runner, redist, launch, live, exeicon, redirect, kit = (read(f) for f in engine)
for name, text in (("BCDGameSetupRules", rules), ("BCDGameSetupTables", tables), ("BCDGameSetupPage", page), ("BCDRegistryEdit", registry), ("BCDGameFixRun", runner)):
    imports = set(re.findall(r"^import (\w+)", text, re.M))
    check(f"{name}.swift: Foundation only (the host check compiles it on this Mac)", imports == {"Foundation"}, imports)
check("BCDExeIcon.swift: Foundation, CoreGraphics and ImageIO only", set(re.findall(r"^import (\w+)", exeicon, re.M)) == {"CoreGraphics", "Foundation", "ImageIO"})
check("the preview build reads the three top-level files (no engine type in them) and not the engine folder",
      not re.search(r"\b(LibraryEntry|LibraryModel|LogStore|GameProfile|DockReset|BCDRegistryEdit|MadeiraConfig)\b", code(rules + tables + page)))
ui_preview = read(R / "tools/ui-preview.py")
check("the preview build still globs BCD*.swift of the top folder only", 'APP.glob("BCD*.swift")' in ui_preview)

# The hooks into older files: one line each.
page_live = read(APP / "BCDGamePageLive.swift")
check("BCDGamePageLive: the sections are inserted once, after Compatibility, only while Options is open",
      page_live.count("setupGroups(game, entry, profile)") == 1 and page_live.index("compatibility(entry), controls(entry, profile), gyro(entry)]") < page_live.index("setupGroups(game, entry, profile)")
      < page_live.index("if let binds = binds(entry)"))
check("BCDGamePageLive: set() hands the sections' rows over once, before the page's own cases",
      page_live.count("setupSet(setting, to: value, for: game)") == 1 and page_live.index("setupSet(setting") < page_live.index('let on = value == "1"'))
library = read(APP / "Library.swift")
check("LibraryEntry.applyEnvironment calls the launch hook once, after the game's own lines are applied",
      library.count("BCDGameSetup.prepare(self)") == 1 and library.index("MadeiraConfig.applyGame(gameConfigText)") < library.index("BCDGameSetup.prepare(self)")
      < library.index('fputs("[frontend] launch profile applied\\n", stderr)') + 400)
check("no other file names the setup engine", all("BCDGameSetup." not in read(f) for f in APP.glob("*.swift")
                                                  if f.name not in ("Library.swift", "BCDGameSetupPage.swift", "BCDGameSetupRules.swift", "BCDGameSetupTables.swift")))

# Launch chips (C7).
chips = read(APP / "BCDGameChips.swift")
page_src_all = read(APP / "BCDGamePage.swift")
check("BCDGameChips.swift: BCD's licence header, built by the Xcode project", read(APP / "BCDGameChips.swift").split("\n")[:3] == HEADER
      and project.count("/* BCDGameChips.swift in Sources */") == 2)
check("the text page shows the quick picks once, only for a setting that has some", page_src_all.count("BCDGameChipGrid(chips: setting.chips, text: $draft)") == 1
      and "if !setting.chips.isEmpty" in page_src_all)
check("only the Launch arguments setting has chips, and a tap changes the page's draft, not the saved text",
      page_live.count("chips: BCDLaunchFlags.quick") == 1 and "@Binding var text: String" in chips and "model" not in code(chips))

# Prefix tools (C2), the icon row (C15) and saves outside the prefix (A12).
settings_sections = read(APP / "BCDSettingsSections.swift")
settings_live = read(APP / "BCDSettingsLive.swift")
tools = read(APP / "BCDPrefixTools.swift")
tools_live = read(SETUP / "BCDPrefixToolsLive.swift")
check("BCDPrefixTools.swift and BCDPrefixToolsLive.swift: licence header, Xcode project",
      all(read(f).split("\n")[:3] == HEADER for f in (APP / "BCDPrefixTools.swift", SETUP / "BCDPrefixToolsLive.swift", SETUP / "BCDPrefixKit.swift", SETUP / "BCDSaveRedirect.swift", SETUP / "BCDExeIcon.swift"))
      and all(project.count(f"/* {f} in Sources */") == 2 for f in ("BCDPrefixTools.swift", "BCDGameSetup/BCDPrefixToolsLive.swift", "BCDGameSetup/BCDPrefixKit.swift", "BCDGameSetup/BCDSaveRedirect.swift", "BCDGameSetup/BCDExeIcon.swift")))
check("Settings > Storage shows the prefix tools through one hook, after Saves and before the shared files",
      settings_sections.count("if let tools = backend.prefixToolsView { tools }") == 1 and settings_sections.index("backend.prefixToolsView") < settings_sections.index('BCDSettingsGroup(title: "Shared files"')
      and settings_sections.index('title: backend.savesBusy ? "Working…" : "Back up every save"') < settings_sections.index("backend.prefixToolsView { tools }"))
check("the storage backend protocol has the prefix tools with a default of none (the preview's sample backends need nothing)",
      "var prefixToolsView: AnyView? { get }" in settings_sections and "var prefixToolsView: AnyView? { nil }" in settings_sections)
check("only the live storage backend names the live tools, in one line", settings_live.count("BCDPrefixToolsLive.shared") == 1)
check("every prefix action waits for the session to end and stops when it cannot make its 'Before' copy first",
      "guard !busy, blocked == nil else { return }" in tools_live and tools_live.count("try Self.before(") == 3 and "wineserver_is_running() != 0" in tools_live)
check("the prefix tools never name an external drive and never touch games (the kit has only the registry, users and ProgramData)",
      "drive_c/users" in kit and "drive_c/ProgramData" in kit and "Games" not in code(kit) and "windows" in kit)
check("the prefix kit refuses entries outside its own part on import, and files that are not copies on put back",
      "allowed(parts)" in kit and kit.count("allowed(") >= 3 and "That is not a copy BCD made." in kit)
check("a fresh registry refuses another Windows user before it makes any copy", tools_live.index("requireUser") < tools_live.index('try Self.before("Before reconfigure")'))
check("Wine's system files: nothing that exists with content is replaced", "== 0 else { continue }" in kit)
check("the icon row hooks once into the Library section, for a game with no store picture", page_live.count("exeIconRows(entry)") == 1 and "entry.coverFile == nil" in live and "entry.steamAppID == nil" in live)
check("the program is only read for its icon (no write to it): BCDExeIcon reads through a memory map and writes nothing", ".alwaysMapped" in exeicon and "write(" not in code(exeicon))
check("a save folder moves only with no session, and only roots that are eligible folders", "guard !Self.sessionRunning" in live and "BCDSaveRedirect.isEligible" in live)
check("the redirect never deletes: its only removal is the link a restore replaces", len(re.findall(r"removeItem", code(redirect))) == 2 and "try fm.removeItem(at: target)   // the link only" in redirect
      and "if list.isEmpty { try? FileManager.default.removeItem(at: url); return }" in redirect)
check("redirect links are relative", "relativePath(from: source, to: destination)" in redirect and "withDestinationPath: relative" in redirect)

# How a game starts (C8, C9).
start_page = read(APP / "BCDGameStart.swift")
start_launch = read(SETUP / "BCDGameStartLaunch.swift")
helper_c = read(R / "bcd-helper/helper.c")
check("BCDGameStart.swift and BCDGameStartLaunch.swift: licence header, Xcode project, Foundation only (the first)",
      read(APP / "BCDGameStart.swift").split("\n")[:3] == HEADER and read(SETUP / "BCDGameStartLaunch.swift").split("\n")[:3] == HEADER
      and project.count("/* BCDGameStart.swift in Sources */") == 2 and project.count("/* BCDGameSetup/BCDGameStartLaunch.swift in Sources */") == 2
      and set(re.findall(r"^import (\w+)", start_page, re.M)) == {"Foundation"})
check("the start wrapper changes the session's start only for the game's own start with a plan (never a Steam Dock start, the desktop, or another program's start)",
      "guard !plan.isEmpty, entry.usesLaunchOptions, entry.desktop != true else { return lines }" in start_launch and "another program's (BCD Host); left as it is" in start_launch
      and start_launch.count('setenv("MADEIRA_EXE"') == 2)
check("the wrapper runs from prepare, after the game's own lines", "wrapStart(entry, values: values)" in launch)
check("no new read of an engine variable by a literal name (the settings catalog lists where each is read): getenv gets a variable, not a string",
      not re.search(r'getenv\(\s*"(MADEIRA|DXMT|MYTHIC)_', "\n".join(read(f) for f in engine + top + [APP / "BCDGameStart.swift", APP / "BCDPrefixTools.swift", APP / "BCDGameChips.swift", SETUP / "BCDGameStartLaunch.swift", SETUP / "BCDPrefixToolsLive.swift"])))
check("the game starts as it always did when the start files cannot be written", "the game starts as it always did" in start_launch)
check("the start script starts cmd.exe by its full system path (the one program the engine runs in its own core)", r'setenv("MADEIRA_EXE", "C:\\windows\\system32\\cmd.exe", 1)' in start_launch)
check("the helper's name holds 'helper' (the session-end check ignores it) and it is copied beside the scripts, not into the farm", "bcd-helper-x64.exe" in start_page and "helper" in "bcd-helper-x64.exe" and "copyHelper" in start_launch)
check("the helper never reaches into another program: no memory, hook, thread or debug API", not re.search(r"WriteProcessMemory|ReadProcessMemory|CreateRemoteThread|VirtualAllocEx|SetWindowsHookEx|DebugActiveProcess|NtSuspend|SuspendThread|LoadLibrary|CreateProcess|ShellExecute", helper_c))
check("the helper opens a process only to read its path or to close the second program", set(re.findall(r"OpenProcess\((\w+)", helper_c)) == {"PROCESS_QUERY_LIMITED_INFORMATION", "PROCESS_TERMINATE"} and helper_c.count("TerminateProcess(") == 1)
check("the helper's CI steps: its host check and its build", "python3 tests/host/check-bcd-helper.py" in read(R / ".github/workflows/build-ipa.yml") and "bash tools/build-bcd-helper.sh" in read(R / ".github/workflows/build-ipa.yml"))

# Nothing runs for a game that never set any of it.
check("prepare returns before touching the registry or a file when the file has no setup line and the prefix holds no state or moved saves",
      launch.index("guard owned || wantsFixes || wantsRegistry || movedSaves || wantsStart else { return }") < launch.index("BCDGameFixRunner.run") < launch.index("BCDRegistryEdit.apply"))
check("a missing state file and no managed edit: the registry editor does nothing at all",
      re.search(r"if managed\.isEmpty, permanent\.isEmpty, state\.owned\.isEmpty \{ return result \}", registry) is not None)
check("the registry is written whole to a hidden name and moved into place", ".bcd-part" in registry and "replaceItemAt" in registry)
check("only BCDGameSetupLaunch.prepare edits the registry, and only before the session (it is called from applyEnvironment, the launch worker's first step)",
      "BCDRegistryEdit.apply" in launch and "BCDRegistryEdit.apply" not in live)
check("the launch hook never throws (no try in it that is not handled)", "try!" not in code(launch) and "throws" not in code(launch))

# What a fix can never do.
check("a fix cannot write a program, a library or a script (the extension list)",
      all(f'"{e}"' in rules for e in ("exe", "dll", "sys", "ocx", "bat", "cmd", "msi")) and "mayWriteFile" in runner)
check("C:\\windows is closed to every action", re.search(r'case "windows": return nil', rules) is not None)
check("an ini or write on a file that starts with MZ is refused", 'Data([0x4D, 0x5A])' in runner and "0x4D, b[1] == 0x5A" in runner)
check("a delete moves aside (no removeItem on the player's file)", "moveItem(at: file, to: target)" in runner
      and len(re.findall(r"removeItem", code(runner))) == 1 and "try? fm.removeItem(at: target)" in runner)
check("the redist action writes into the game's own folder only and checks the bytes are a DLL", "mayPlaceLibrary" in runner and "isGame" in rules and 'data.prefix(2) == Data([0x4D, 0x5A])' in runner)
check("no network, no process, no shell in the setup engine", not re.search(r"URLSession|Process\(|posix_spawn|system\(|dlopen|NSTask", code(registry + runner + redist + launch + live)))
check("log lines carry the game's title and counts, not paths", "[game-fix]" in runner and "[game-setup]" in launch and "mythic" not in launch)
check("the player's lines are written through GameProfile (one place), never by a second writer", "GameProfile(windowsPath: entry.windowsPath)" in live and code(live).count("write(to:") == 2)   # the temporary cover picture and the wallpaper bitmap; every other line goes through GameProfile

# The words
check("the default of every row is no line (Windows 10 / BCD's own choice / none)", page.count('defaultValue: ""') >= 4)
check("removing a fix asks first", "question: removeQuestion(item)" in page)
check("the tables name only keys the engine reads (env.FEX_*, env.MADEIRA_APP_DLL_SHADOW, env.WINEDLLOVERRIDES)",
      all(k in tables for k in ("env.FEX_TSOENABLED", "env.FEX_VECTORTSOENABLED", "env.FEX_MEMCPYSETTSOENABLED", "env.FEX_HALFBARRIERTSOENABLED", "env.FEX_MULTIBLOCK", "env.FEX_SMCCHECKS",
                                "env.MADEIRA_APP_DLL_SHADOW", "env.WINEDLLOVERRIDES")))
policy = read(APP / "GameRecommendationsList.swift")
check("a downloaded list cannot carry the setup keys (they are not catalog keys): nothing here edits the policy or the catalog",
      "win.version" not in policy and "fix." not in policy and "desktop.dpi" not in policy)

workflow = read(R / ".github/workflows/build-ipa.yml")
check("CI runs this check", "python3 tests/host/check-game-setup.py" in workflow)

# ------------------------------------------------------------------------------ Parts B, C, D: compiled and run
if not shutil.which("xcrun"):
    check("xcrun swiftc is here for the Swift parts", not args.require_swift)
else:
    with tempfile.TemporaryDirectory(prefix="game-setup-") as tmp:
        t = Path(tmp)
        # B: the template's real registry files
        with tarfile.open(APP / "prefix-template.tar.gz") as tar:
            for name in ("user.reg", "system.reg"):
                (t / name).write_bytes(tar.extractfile("prefix/" + name).read())
        zip_src = read(APP / "SavesAndShortcuts.swift")
        writer = zip_src[zip_src.index("final class SaveZipWriter {"):zip_src.index("// MARK: - Zip reading")]
        reader = zip_src[zip_src.index("struct SaveZipReader {"):zip_src.index("// MARK: - Save backups")]
        support = ("import Foundation\nimport Compression\nimport zlib\n\nenum LibraryError: LocalizedError {\n    case message(String)\n"
                   "    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }\n}\n\n" + writer + "\n" + reader)
        (t / "ZipSupport.swift").write_text(support)
        store = read(APP / "BCDStore.swift")
        (t / "dates.swift").write_text("import Foundation\n\nenum BCDFormat {\n" + store[store.index("    // dates-begin"):store.index("    // dates-end")] + "}\n")
        shutil.copy(R / "tests/host/game_setup_host.swift", t / "main.swift")
        sources = [t / "main.swift", t / "dates.swift", APP / "DockReset.swift", APP / "BCDGameSetupRules.swift", SETUP / "BCDRegistryEdit.swift", SETUP / "BCDGameFixRun.swift",
                   SETUP / "BCDExeIcon.swift", SETUP / "BCDWallpaper.swift", SETUP / "BCDSaveRedirect.swift", SETUP / "BCDPrefixKit.swift", APP / "BCDSaveBackups/GameSaveRules.swift", t / "ZipSupport.swift"]
        r = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-o", str(t / "setup")] + [str(s) for s in sources], capture_output=True, text=True)
        check("the rules, the registry editor and the fix runner compile on their own with DockReset.swift", r.returncode == 0, (r.stderr or r.stdout)[-3000:])
        if r.returncode == 0:
            r = subprocess.run([str(t / "setup"), str(t / "user.reg"), str(t / "system.reg"), str(APP / "arm64ec-windows/7zFM.exe"), str(APP / "aarch64-windows/notepad.exe")],
                               capture_output=True, text=True, timeout=300)
            print("\n".join("     " + line for line in r.stdout.strip().split("\n") if line.startswith("FAIL") or line.startswith("     ") or "checks," in line))
            check("game setup holds (words, fixes, places, ini text, registry file edits, the runner)", r.returncode == 0, (r.stdout + r.stderr)[-2500:])

        # C: the sections' words and rows, with the page's rules
        page_src = read(APP / "BCDGamePage.swift")
        start = page_src.index("// MARK: - The page's rules")
        end = page_src.index("// MARK: - Opening the page")
        u = t / "ui"
        u.mkdir()
        (u / "Rules.swift").write_text("import Combine\nimport Foundation\nimport SwiftUI\n\n" + page_src[start:end])
        shutil.copy(R / "tests/host/game_setup_ui_host.swift", u / "main.swift")
        names = ("BCDStore.swift", "BCDGameDLC.swift", "BCDGameSetupRules.swift", "BCDGameSetupTables.swift", "BCDGameSetupPage.swift", "BCDGameStart.swift")
        for n in names:
            shutil.copy(APP / n, u / n)
        r = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-o", str(u / "ui")] + [str(u / n) for n in names + ("Rules.swift", "main.swift")], capture_output=True, text=True)
        check("the sections' words and rows compile with the page's rules", r.returncode == 0, (r.stderr or r.stdout)[-3000:])
        if r.returncode == 0:
            r = subprocess.run([str(u / "ui"), str(t / "supervisor.txt"), "-AppleLocale", "en_US", "-AppleLanguages", "(en)"], capture_output=True, text=True, timeout=120)
            print("\n".join("     " + line for line in r.stdout.strip().split("\n") if line.startswith("FAIL") or line.startswith("     ") or "checks," in line))
            check("the sections hold (tables, presets, rows, notes, questions)", r.returncode == 0, (r.stdout + r.stderr)[-2500:])

        # The supervisor's file as the Swift side writes it, read by the helper's own C reader.
        if (t / "supervisor.txt").exists():
            hc = subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I" + str(R / "bcd-helper"), "-o", str(t / "file_test"), str(R / "bcd-helper/file_test.c")], capture_output=True, text=True)
            check("the helper's file reader compiles", hc.returncode == 0, hc.stderr[-1500:])
            if hc.returncode == 0:
                out = subprocess.run([str(t / "file_test"), str(t / "supervisor.txt")], capture_output=True, text=True).stdout.split("\n")
                check("the helper reads what the Swift side writes: game, program, second program, stop, wait and the two rules",
                      out[:9] == ["game=c:\\games\\foo", "program=foo.exe", "second=mapper.exe", "stop=1", "wait=5", "rules=2", "log=C:\\bcd-games\\ID-start.log", "rule1=1|1|Final Fantasy IX|1000", "rule2=3|1|Launcher|250"], out)
        # The protection names are one list in two languages.
        swift_list = re.search(r"static let list = \[(.*?)\n    \]", read(APP / "BCDGameStart.swift"), re.S).group(1)
        c_list = re.search(r"names\[\] = \{(.*?)\};", read(R / "bcd-helper/core.h"), re.S).group(1)
        check("BCDProtection.list and the helper's hr_is_protection list name the same programs",
              sorted(re.findall(r'"([^"]+)"', swift_list)) == sorted(re.findall(r'"([^"]+)"', c_list)))

        # D: the redistributable reader
        d = t / "redist"
        d.mkdir()

        def cab(files, lzx=False):
            """A cabinet with one folder, stored (or marked LZX); files: [(name, bytes)]."""
            body = b"".join(data for _, data in files)
            cffiles = b""
            off = 0
            for name, data in files:
                cffiles += struct.pack("<IIHHHH", len(data), off, 0, 0x5A21, 0x6000, 0x20) + name.encode() + b"\0"
                off += len(data)
            header_size = 36 + 8
            coff_files = header_size
            coff_data = coff_files + len(cffiles)
            blocks = b""
            pos = 0
            n = 0
            while pos < len(body) or n == 0:
                chunk = body[pos:pos + 32768]
                blocks += struct.pack("<IHH", 0, len(chunk), len(chunk)) + chunk
                pos += len(chunk)
                n += 1
                if not chunk:
                    break
            total = coff_data + len(blocks)
            hdr = b"MSCF" + struct.pack("<IIIIIBBHHHHH", 0, total, 0, coff_files, 0, 3, 1, 1, len(files), 0, 1, 0)
            folder = struct.pack("<IHH", coff_data, n, 0x1503 if lzx else 0)
            return hdr + folder + cffiles + blocks

        def dll(tag):
            return b"MZ" + bytes([tag]) * 3000

        (d / "plain.cab").write_bytes(cab([("Docs\\readme.txt", b"hello"), ("Bin\\xinput1_3.dll", dll(1))]))
        inner = cab([("d3dx9_43.dll", dll(2))])
        outer = cab([("dx.cab", inner), ("other.txt", b"x" * 100)])
        (d / "nested.exe").write_bytes(b"MZ" + b"\x90" * 500 + b"junk MSCF not a cabinet" + b"\0" * 64 + outer + b"\0" * 32)
        with zipfile.ZipFile(d / "archive.zip", "w", zipfile.ZIP_STORED) as z:
            z.writestr("sub/xinput1_3.dll", dll(3))
            z.writestr("a.txt", "x")
        (d / "lzx.cab").write_bytes(cab([("xinput1_3.dll", dll(4))], lzx=True))
        (d / "empty.bin").write_bytes(b"\0" * 2048)
        (t / "cab-bridge.h").write_text('#include "%s"\n' % (APP / "BCDCab.h"))
        rd = t / "rd"
        rd.mkdir()
        shutil.copy(R / "tests/host/game_setup_redist_host.swift", rd / "main.swift")
        shutil.copy(t / "ZipSupport.swift", rd / "ZipSupport.swift")
        c = subprocess.run(["xcrun", "clang", "-c", "-O1", "-o", str(rd / "BCDCab.o"), str(APP / "BCDCab.c")], capture_output=True, text=True)
        check("BCDCab.c compiles on this Mac", c.returncode == 0, c.stderr[-1500:])
        if c.returncode == 0:
            r = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-import-objc-header", str(t / "cab-bridge.h"), "-o", str(rd / "redist"),
                                str(rd / "main.swift"), str(rd / "ZipSupport.swift"), str(SETUP / "BCDGameFixRedist.swift"), str(rd / "BCDCab.o"), "-lz"],
                               capture_output=True, text=True)
            check("the redistributable reader compiles with BCDCab and the production zip reader", r.returncode == 0, (r.stderr or r.stdout)[-3000:])
            if r.returncode == 0:
                r = subprocess.run([str(rd / "redist"), str(d)], capture_output=True, text=True, timeout=120)
                print("\n".join("     " + line for line in r.stdout.strip().split("\n") if line.startswith("FAIL") or line.startswith("     ") or "checks," in line))
                check("the reader holds (cabinet, nested cabinet in a program, zip, LZX refused, no cabinet)", r.returncode == 0, (r.stdout + r.stderr)[-2500:])

print("PASS: game setup" if ok else "FAIL: game setup")
sys.exit(0 if ok else 1)
