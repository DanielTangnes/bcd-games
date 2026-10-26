// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
//
// The host check for BCD's game setup (app/Madeira/BCDGameSetup/, round 604): compiled with DockReset.swift (the .reg text editor
// it extends), GameSaveRules.swift and GameSaveBackups.swift (the path helpers it reuses) and run on a prefix built in a scratch
// folder. argv[1] is a real user.reg (the shipped template's), argv[2] a real system.reg. Prints "ok" / "FAIL" lines.

import CoreGraphics
import Foundation
import ImageIO

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    checks += 1
    if !ok { failures += 1 }
    print((ok ? "ok   " : "FAIL ") + what + (ok || detail.isEmpty ? "" : "\n     " + detail))
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("bcd-game-setup-\(UUID().uuidString)")
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

func write(_ url: URL, _ text: String) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.data(using: .utf8)!.write(to: url)
}
func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

let realUser = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let realSystem = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let programs = Array(CommandLine.arguments.dropFirst(3))   // real Windows programs with icons: 7zFM.exe (bitmap icons), notepad.exe (PNG icon)

// ------------------------------------------------------------------------------ words
do {
    check(BCDSetupText.words("ini \"%DOCUMENTS%\\My Games\\a b.ini\" Display \"Full\"\"Screen\" 1")
          == ["ini", "%DOCUMENTS%\\My Games\\a b.ini", "Display", "Full\"Screen", "1"], "quoted words keep blanks, backslashes and doubled quotes")
    check(BCDSetupText.words("a \"\" b") == ["a", "", "b"], "an empty quoted word is a word")
    check(BCDSetupText.words("a \"b") == nil, "an open quote is refused")
    check(BCDSetupText.words("a\0b") == nil, "a NUL is refused")
    check(BCDSetupText.words("  ") == [], "blanks only: no words")
    for sample in ["plain", "with space", "q\"uote", "C:\\Games\\", "tab\there", "", "%GAME%\\"] {
        check(BCDSetupText.words(BCDSetupText.quote(sample)) == [sample], "quote then read gives \(sample.debugDescription) back")
    }
    check(BCDSetupText.decodeText("a\\nb\\\\c\\td\\Ge") == "a\nb\\c\td\\Ge", "write text: \\n \\\\ \\t decode, another backslash stays")
    for sample in ["line1\nline2\r\n", "C:\\Games\\x", "tab\t", "back\\n literally"] {
        check(BCDSetupText.decodeText(BCDSetupText.encodeText(sample)) == sample, "write text round trip \(sample.debugDescription)")
    }
}

// ------------------------------------------------------------------------------ fixes: lines
do {
    let lines = [
        "ini \"%DOCUMENTS%\\My Games\\Foo\\foo.ini\" Display FullScreen 1",
        "ini-remove \"%GAME%\\a.ini\" \"\" Key",
        "reg HKCU\\Software\\Foo Intro dword 0",
        "reg HKLM\\Software\\Wow6432Node\\Foo \"\" sz \"C:\\Games\\Foo\"",
        "reg HKCU\\Software\\Foo Path expand %GAME%",
        "reg HKCU\\Software\\Foo Blob binary \"01 0a ff\"",
        "reg-delete HKCU\\Software\\Foo Old",
        "delete \"%LOCALAPPDATA%\\Foo\\ShaderCache\"",
        "write \"%GAME%\\autoexec.cfg\" missing \"bind x quit\\n\"",
        "redist \"%GAME%\\redist\\dx.cab\" xinput1_3.dll \"%GAME%\\\" replace",
    ]
    for line in lines {
        let parsed = BCDFixAction.parse(line)
        check(parsed.action != nil, "parses: \(line)", parsed.error ?? "")
        if let action = parsed.action {
            check(BCDFixAction.parse(action.line).action == action, "its line reads back to the same action", action.line)
            check(!action.summary.isEmpty, "has a summary")
        }
    }
    let bad = ["", "ini a b", "ini x s \"=\" v", "reg HKCU\\Software\\Foo n dword 4294967296", "reg HKLM\\System\\CurrentControlSet\\Services x sz y",
               "reg HKXX\\a n sz y", "reg HKCU n sz y", "write f sometimes t", "redist a b.exe c", "redist a b.dll", "wibble x", "ini \"open",
               "reg HKCU\\a n binary \"zz\"", "ini f \"[bad]\" k v"]
    for line in bad { check(BCDFixAction.parse(line).action == nil, "refused: \(line.debugDescription)") }

    let values = ["fix.2": lines[2], "fix.1": lines[0], "fix-off.3": lines[7], "fix.x": "ini", "fix.4": "nonsense", "fix-off.1": lines[1], "other": "1"]
    let listed = BCDGameFixes.list(values)
    check(listed.fixes.map(\.number) == [1, 2, 3], "listed in number order, the on line winning over the same number off", "\(listed.fixes.map(\.number))")
    check(listed.fixes.map(\.enabled) == [true, true, false], "on/off read from the key")
    check(listed.problems.count == 2, "two lines name no fix", "\(listed.problems)")
    check(BCDGameFixes.nextNumber(values) == 5, "next free number")
    check(BCDGameFixes.nextNumber([:]) == 1, "next free number in an empty file")
}

// ------------------------------------------------------------------------------ registry values and keys
do {
    check(BCDRegValue.string("a\"b\\c").regText == "\"a\\\"b\\\\c\"", "string escapes")
    check(BCDRegValue.string("é").regText == "\"\\x00e9\"", "non-ASCII as \\x", BCDRegValue.string("é").regText)
    check(BCDRegValue.dword(96).regText == "dword:00000060", "dword")
    check(BCDRegValue.expandString("%A%").regText == "str(2):\"%A%\"", "expand string")
    check(BCDRegValue.binary([1, 0xAB]).regText == "hex:01,ab", "binary")
    check(BCDRegKey.parse("HKCU\\Software\\Foo")?.file == "user.reg" && BCDRegKey.parse("hklm\\Software\\Foo")?.file == "system.reg", "hives")
    check(BCDRegKey.parse("HKEY_CURRENT_USER/Software/Foo")?.path == "Software\\Foo", "long hive name and slashes")
    check(BCDRegKey.parse("HKLM\\System\\X") == nil && BCDRegKey.parse("HKCU\\System\\X") != nil, "HKLM\\System is closed, HKCU\\System is not")
    check(BCDRegKey.parse("HKCU\\a\\\\b") == nil, "an empty component is refused")
    check(BCDWindowsVersion.registryValue("winxp", is64Bit: false) == "winxp" && BCDWindowsVersion.registryValue("winxp", is64Bit: true) == "winxp64", "Windows XP is winxp64 for a 64-bit program")
    check(BCDWindowsVersion.registryValue("", is64Bit: true) == nil && BCDWindowsVersion.registryValue("win7", is64Bit: true) == "win7", "default is no entry")
    check(BCDWindowsVersion.registryValue("win3000", is64Bit: false) == nil, "an unknown id is no entry")
    check(BCDWindowsVersion.isProgramName("Game.exe") && !BCDWindowsVersion.isProgramName("a\\b.exe") && !BCDWindowsVersion.isProgramName("x.dll"), "program names")
    check(Set(BCDWindowsVersion.all.map(\.id)).count == BCDWindowsVersion.all.count, "version ids are unique")
}

// ------------------------------------------------------------------------------ places
let drive = scratch.appendingPathComponent("prefix/drive_c")
for sub in ["users/mythic/Documents", "users/Public/Documents", "users/mythic/AppData/Roaming", "Games/Foo", "windows/system32", "ProgramData", "Program Files/Foo"] {
    try! fm.createDirectory(at: drive.appendingPathComponent(sub), withIntermediateDirectories: true)
}
let ctx = BCDFixPaths.Context(users: ["mythic", "Public"], install: "Games/Foo")
do {
    func r(_ s: String) -> String? { BCDFixPaths.resolve(s, ctx)?.joined(separator: "/") }
    check(r("%DOCUMENTS%\\My Games\\Foo\\a.ini") == "users/mythic/Documents/My Games/Foo/a.ini", "%DOCUMENTS%")
    check(r("%appdata%\\Foo") == "users/mythic/AppData/Roaming/Foo", "%APPDATA% in any case")
    check(r("%LOCALAPPDATA%\\Foo") == "users/mythic/AppData/Local/Foo" && r("%LOCALLOW%\\Foo") == "users/mythic/AppData/LocalLow/Foo", "local and low")
    check(r("%GAME%\\bin\\x.cfg") == "Games/Foo/bin/x.cfg" && r("%GAME%\\") == "Games/Foo", "%GAME%")
    check(r("%PUBLIC%\\Documents") == "users/Public/Documents" && r("%PROGRAMDATA%\\Foo") == "ProgramData/Foo", "public and ProgramData")
    check(r("C:\\Games\\Foo\\x") == "Games/Foo/x" && r("c:/Games/Foo/x") == "Games/Foo/x", "an absolute C: path")
    check(r("D:\\x") == nil && r("x\\y") == nil && r("%NOPE%\\x") == nil && r("%GAME%x") == nil, "other drives, relative paths and unknown tokens are refused")
    check(r("C:\\Games\\..\\windows") == nil && r("%GAME%\\..\\..\\x") == nil, "no .. anywhere")
    check(BCDFixPaths.resolve("%GAME%\\x", BCDFixPaths.Context(users: ["mythic"], install: nil)) == nil, "%GAME% needs a game folder")
    check(BCDFixPaths.resolve("%DOCUMENTS%\\x", BCDFixPaths.Context(users: ["Public"], install: nil)) == nil, "%DOCUMENTS% needs a user")

    func may(_ s: String, _ f: ([String], BCDFixPaths.Context) -> Bool) -> Bool { BCDFixPaths.resolve(s, ctx).map { f($0, ctx) } ?? false }
    check(may("%DOCUMENTS%\\a.ini", BCDFixPaths.mayWriteFile), "a file in Documents may be written")
    check(!may("%DOCUMENTS%", BCDFixPaths.mayWriteFile) && may("%APPDATA%\\a.ini", BCDFixPaths.mayWriteFile), "Documents itself no, a file in Roaming yes")
    check(!may("C:\\windows\\win.ini", BCDFixPaths.mayWriteFile) && !may("C:\\windows\\system32\\x.txt", BCDFixPaths.mayDelete), "C:\\windows is closed")
    check(!may("%GAME%\\Game.exe", BCDFixPaths.mayWriteFile) && !may("%GAME%\\a.dll", BCDFixPaths.mayWriteFile) && !may("%GAME%\\run.bat", BCDFixPaths.mayWriteFile),
          "no program or script is written")
    check(!may("%GAME%\\Game.exe", BCDFixPaths.mayDelete), "no program is deleted")
    check(!may("%GAME%\\", BCDFixPaths.mayDelete) && may("%GAME%\\Cache", BCDFixPaths.mayDelete), "the game's folder itself is not deleted, a folder in it is")
    check(!may("%DOCUMENTS%", BCDFixPaths.mayDelete) && !may("%LOCALAPPDATA%", BCDFixPaths.mayDelete) && may("%LOCALAPPDATA%\\Foo", BCDFixPaths.mayDelete),
          "a profile folder is not deleted, a folder below it is")
    check(!may("C:\\Program Files", BCDFixPaths.mayDelete) && may("C:\\Program Files\\Foo", BCDFixPaths.mayDelete) && !may("C:\\ProgramData", BCDFixPaths.mayDelete), "program-files roots are not deleted")
    check(!may("C:\\users", BCDFixPaths.mayDelete) && !may("C:\\users\\mythic", BCDFixPaths.mayDelete) && !may("C:\\Other", BCDFixPaths.mayDelete), "users and other top folders are not deleted")
    check(!may("C:\\External\\Games\\Foo\\a.ini", BCDFixPaths.mayWriteFile) && !may("C:\\external\\x", BCDFixPaths.mayDelete)
          && BCDFixPaths.zone(["External", "Games", "x.ini"], BCDFixPaths.Context(users: ["mythic"], install: "External/Games")) == nil, "nothing under C:\\External (an external drive's games) is touched, even as a game's own folder")
    check(may("%GAME%\\", BCDFixPaths.mayPlaceLibrary) && may("%GAME%\\bin\\x.dll", BCDFixPaths.mayPlaceLibrary) && !may("%DOCUMENTS%\\x.dll", BCDFixPaths.mayPlaceLibrary)
          && !may("C:\\windows\\system32\\x.dll", BCDFixPaths.mayPlaceLibrary), "a library goes only into the game's folder")
}

// ------------------------------------------------------------------------------ ini text
do {
    let crlf = "[Display]\r\nWidth = 800\r\nFullScreen=0\r\n\r\n[Sound]\r\n; a comment\r\nVolume=5\r\n"
    let a = BCDIniText.set(crlf, section: "Display", key: "FULLSCREEN", value: "1")
    check(a == "[Display]\r\nWidth = 800\r\nFullScreen=1\r\n\r\n[Sound]\r\n; a comment\r\nVolume=5\r\n", "an existing key is rewritten in place, spelling and CRLF kept", a.debugDescription)
    check(BCDIniText.set(crlf, section: "Display", key: "width", value: "800") == crlf, "the same value changes nothing")
    let b = BCDIniText.set(crlf, section: "Display", key: "Height", value: "600")
    check(b == "[Display]\r\nWidth = 800\r\nFullScreen=0\r\nHeight = 600\r\n\r\n[Sound]\r\n; a comment\r\nVolume=5\r\n", "a new key goes at the end of its section, in the section's spacing", b.debugDescription)
    let c = BCDIniText.set(crlf, section: "Video", key: "Vsync", value: "0")
    check(c == crlf + "\r\n[Video]\r\nVsync=0\r\n", "a new section goes at the end", c.debugDescription)
    let d = BCDIniText.set("Key=1\nOther=2\n[S]\nA=1\n", section: "", key: "New", value: "x")
    check(d == "Key=1\nOther=2\nNew=x\n[S]\nA=1\n", "the part before any section is the empty section", d.debugDescription)
    check(BCDIniText.set("", section: "S", key: "K", value: "v") == "[S]\r\nK=v\r\n", "a new file gets Windows line breaks")
    check(BCDIniText.set("[S]\nK=1", section: "S", key: "K", value: "2") == "[S]\nK=2", "no final line break stays none")
    check(BCDIniText.remove(crlf, section: "Display", key: "width") == "[Display]\r\nFullScreen=0\r\n\r\n[Sound]\r\n; a comment\r\nVolume=5\r\n", "remove")
    check(BCDIniText.remove(crlf, section: "Display", key: "nope") == crlf, "removing a missing key changes nothing")
    check(BCDIniText.value(of: "volume", section: "sound", in: crlf) == "5", "read a value")
    check(BCDIniText.set("[S]\n;K=1\nK=2\n", section: "S", key: "K", value: "3") == "[S]\n;K=1\nK=3\n", "a commented key is not the key")
    // encodings
    let utf16 = BCDIniText.encode("[S]\r\nK=é\r\n", .utf16LE)!
    let decoded = BCDIniText.decode(utf16)
    check(decoded?.encoding == .utf16LE && decoded?.text == "[S]\r\nK=é\r\n", "UTF-16 with a byte order mark is read and written back as such")
    check(BCDIniText.decode(Data([0x4D, 0x5A, 0x90, 0x00, 0x03]))?.text == nil, "a program is not a text file")
    check(BCDIniText.decode(Data([0x41, 0x00, 0x42, 0x00, 0x43]))?.text == nil, "binary data is not a text file")
    let latin = Data([0x4B, 0x3D, 0xE9, 0x0A])   // K=é in Windows-1252, not UTF-8
    let l = BCDIniText.decode(latin)
    check(l?.encoding == .latin1 && l.flatMap { BCDIniText.encode($0.text, $0.encoding) } == latin, "a non-UTF-8 file keeps its bytes")
    check(BCDIniText.decode(Data([0xEF, 0xBB, 0xBF, 0x4B, 0x3D, 0x31]))?.encoding == .utf8BOM, "UTF-8 with a byte order mark")
}

// ------------------------------------------------------------------------------ registry files
do {
    let prefix = scratch.appendingPathComponent("prefix")
    guard let user = realUser.isEmpty ? nil : read(URL(fileURLWithPath: realUser)) else { check(false, "argv[1] is the template's user.reg"); exit(1) }
    write(prefix.appendingPathComponent("user.reg"), user)
    write(prefix.appendingPathComponent("system.reg"), read(URL(fileURLWithPath: realSystem)) ?? "WINE REGISTRY Version 2\n")
    let userURL = prefix.appendingPathComponent("user.reg")
    let stateURL = prefix.appendingPathComponent(BCDRegistryEdit.stateName)
    let version = BCDRegistryEdit.Edit(file: "user.reg", key: BCDWindowsVersion.appKey(program: "game.exe"), name: "Version", raw: BCDRegValue.string("win7").regText)
    var r = BCDRegistryEdit.apply(managed: [version], prefix: prefix)
    check(r.written == ["user.reg"] && r.changed == 1 && r.problems.isEmpty, "a managed value is written", "\(r)")
    var text = read(userURL) ?? ""
    check(text.contains("[Software\\\\Wine\\\\AppDefaults\\\\game.exe] ") && text.contains("\n\"Version\"=\"win7\"\n"), "in Wine's syntax, under its own key")
    check(text.hasPrefix("WINE REGISTRY Version 2\n") && text.count > user.count, "the rest of the file is still there")
    let reg = DockReset.RegText(text)
    check(reg.sections().contains { $0.path == "software\\wine\\appdefaults\\game.exe" }, "Wine's own parser of the helper (RegText) sees the key")
    check(exists(stateURL), "the state file remembers what BCD wrote")
    r = BCDRegistryEdit.apply(managed: [version], prefix: prefix)
    check(r.written.isEmpty && r.changed == 0, "again: nothing is written", "\(r)")
    // Another value in the same key, another program.
    let other = BCDRegistryEdit.Edit(file: "user.reg", key: BCDWindowsVersion.appKey(program: "other.exe"), name: "Version", raw: BCDRegValue.string("winxp").regText)
    r = BCDRegistryEdit.apply(managed: [version, other], prefix: prefix)
    check(r.changed == 1, "a second program's version is added")
    r = BCDRegistryEdit.apply(managed: [other], prefix: prefix)
    check(r.retracted == 1, "a value no longer wanted goes", "\(r)")
    text = read(userURL) ?? ""
    check(!text.contains("game.exe") && text.contains("other.exe"), "and only that one")
    r = BCDRegistryEdit.apply(managed: [], prefix: prefix)
    check(read(userURL) == user && !exists(stateURL), "with nothing wanted the file is the template's again, byte for byte, and the state is gone")

    // A value that was there before comes back.
    let dpi = BCDRegistryEdit.Edit(file: "user.reg", key: "Control Panel\\Desktop", name: "LogPixels", raw: BCDRegValue.dword(144).regText)
    let before = DockReset.RegText(user).rawValue(key: "Control Panel\\Desktop", name: "LogPixels")
    r = BCDRegistryEdit.apply(managed: [dpi], prefix: prefix)
    check(DockReset.RegText(read(userURL) ?? "").rawValue(key: "Control Panel\\Desktop", name: "LogPixels") == "dword:00000090", "a value of an existing key is replaced", "was \(before ?? "nil")")
    r = BCDRegistryEdit.apply(managed: [], prefix: prefix)
    check(read(userURL) == user, "and put back as it was")
    // Somebody else changed it meanwhile: left alone.
    _ = BCDRegistryEdit.apply(managed: [dpi], prefix: prefix)
    var edited = DockReset.RegText(read(userURL) ?? "")
    edited.setValue(key: "Control Panel\\Desktop", name: "LogPixels", raw: "dword:000000c0", now: Date())
    write(userURL, edited.text)
    r = BCDRegistryEdit.apply(managed: [], prefix: prefix)
    check(r.retracted == 0 && DockReset.RegText(read(userURL) ?? "").rawValue(key: "Control Panel\\Desktop", name: "LogPixels") == "dword:000000c0" && !exists(stateURL),
          "a value changed by somebody else is not touched, and no longer owned", "\(r)")
    write(userURL, user)

    // Permanent edits, system.reg.
    let sys = BCDRegistryEdit.Edit(file: "system.reg", key: "Software\\Wow6432Node\\BCDTest\\Sub", name: "Intro", raw: BCDRegValue.dword(0).regText)
    r = BCDRegistryEdit.apply(managed: [], permanent: [sys], prefix: prefix)
    check(r.written == ["system.reg"] && DockReset.RegText(read(prefix.appendingPathComponent("system.reg")) ?? "").rawValue(key: "Software\\Wow6432Node\\BCDTest\\Sub", name: "intro") == "dword:00000000",
          "a permanent edit goes to system.reg, value names without regard to case", "\(r)")
    check(!exists(stateURL), "and is not remembered")
    var del = sys; del.raw = nil
    r = BCDRegistryEdit.apply(managed: [], permanent: [del], prefix: prefix)
    check(r.changed == 1 && DockReset.RegText(read(prefix.appendingPathComponent("system.reg")) ?? "").rawValue(key: "Software\\Wow6432Node\\BCDTest\\Sub", name: "Intro") == nil, "a permanent removal")

    // A multi-line (hex) value survives an edit of its neighbour, and is replaced whole.
    var withHex = DockReset.RegText(user)
    withHex.setValue(key: "Software\\BCDHex", name: "Blob", raw: "hex:01,02,03,\\\n  04,05", now: Date())
    withHex.setValue(key: "Software\\BCDHex", name: "Next", raw: "dword:00000001", now: Date())
    check(withHex.rawValue(key: "Software\\BCDHex", name: "Blob") == "hex:01,02,03,\\\n  04,05", "a value on two lines is read as one")
    withHex.setValue(key: "Software\\BCDHex", name: "Blob", raw: "dword:00000007", now: Date())
    check(withHex.rawValue(key: "Software\\BCDHex", name: "Blob") == "dword:00000007" && withHex.rawValue(key: "Software\\BCDHex", name: "Next") == "dword:00000001"
          && !withHex.text.contains("04,05"), "replacing it takes its continuation line along")
    check({ var t = DockReset.RegText("[A] 1\n\"x\"=\"1\"\n\n[B] 2\n\"y\"=\"2\"\n"); t.removeValue(key: "A", name: "x", dropEmptyKey: true); return t.text == "[B] 2\n\"y\"=\"2\"\n" }(),
          "removing the last value can take its key with it")

    // Files that cannot be edited are reported, not damaged.
    write(prefix.appendingPathComponent("system.reg"), "")
    try? fm.removeItem(at: prefix.appendingPathComponent("user.reg"))
    r = BCDRegistryEdit.apply(managed: [version], prefix: prefix)
    check(!r.problems.isEmpty && r.written.isEmpty, "a registry file that is missing is a problem, not a crash", "\(r)")
}

// ------------------------------------------------------------------------------ running fixes
do {
    let backups = scratch.appendingPathComponent("Fix Backups/Foo")
    let docs = drive.appendingPathComponent("users/mythic/Documents")
    write(docs.appendingPathComponent("My Games/Foo/foo.ini"), "[Display]\r\nFullScreen=0\r\n")
    write(drive.appendingPathComponent("Games/Foo/Game.exe"), "MZ not really a program")
    write(drive.appendingPathComponent("Games/Foo/cache/a.bin"), "cache")
    write(drive.appendingPathComponent("users/mythic/AppData/Local/Foo/ShaderCache/s.bin"), "shader")
    var setting = BCDGameFixRunner.Setting(drive: drive, context: ctx, backups: backups, extractMember: nil)

    func fixes(_ lines: [String]) -> [BCDGameFix] {
        lines.enumerated().map { BCDGameFix(number: $0.offset + 1, enabled: true, action: BCDFixAction.parse($0.element).action!) }
    }
    let list = fixes([
        "ini \"%DOCUMENTS%\\my games\\foo\\FOO.ini\" Display FullScreen 1",
        "ini \"%DOCUMENTS%\\My Games\\Foo\\new.ini\" Video Vsync 0",
        "write \"%GAME%\\autoexec.cfg\" missing \"bind x quit\\n\"",
        "delete \"%LOCALAPPDATA%\\Foo\\ShaderCache\"",
        "reg HKCU\\Software\\Foo Intro dword 0",
        "reg-delete HKCU\\Software\\Foo Old",
        "ini \"%GAME%\\Game.exe\" S K V",
        "write \"%GAME%\\evil.dll\" always x",
        "delete \"%GAME%\\Game.exe\"",
        "delete \"C:\\windows\\system32\"",
        "write \"C:\\windows\\win.ini\" always x",
    ])
    var out = BCDGameFixRunner.run(list, setting)
    check(read(docs.appendingPathComponent("My Games/Foo/foo.ini")) == "[Display]\r\nFullScreen=1\r\n", "the ini key is set in the file as it is on disk (found without regard to case)")
    check(read(docs.appendingPathComponent("My Games/Foo/new.ini")) == "[Video]\r\nVsync=0\r\n", "a missing ini file is made")
    check(read(drive.appendingPathComponent("Games/Foo/autoexec.cfg")) == "bind x quit\n", "a file is written, with the line break")
    check(!exists(drive.appendingPathComponent("users/mythic/AppData/Local/Foo/ShaderCache")) && read(backups.appendingPathComponent("deleted/users__mythic__AppData__Local__Foo__ShaderCache/s.bin")) == "shader",
          "a folder is moved aside to Fix Backups, not deleted")
    check(read(backups.appendingPathComponent("original/users__mythic__Documents__My Games__Foo__foo.ini")) == "[Display]\r\nFullScreen=0\r\n", "the first original of an edited file is kept")
    check(out.registry.count == 2 && out.registry[0].file == "user.reg" && out.registry[0].key == "Software\\Foo" && out.registry[0].raw == "dword:00000000" && out.registry[1].raw == nil,
          "registry fixes are handed back as edits")
    check(read(drive.appendingPathComponent("Games/Foo/Game.exe")) == "MZ not really a program" && !exists(drive.appendingPathComponent("Games/Foo/evil.dll")), "no program is edited, written or taken")
    check(exists(drive.appendingPathComponent("windows/system32")) && !exists(drive.appendingPathComponent("windows/win.ini")), "C:\\windows is not touched")
    check(out.failed == 5, "the five refused fixes are counted and logged", "\(out.failed)\n\(out.lines.joined(separator: "\n"))")
    check(out.lines.allSatisfy { !$0.contains("mythic") }, "log lines do not carry the Windows user's name", out.lines.joined(separator: "\n"))
    // Again: nothing changes.
    let iniBefore = read(docs.appendingPathComponent("My Games/Foo/foo.ini"))
    out = BCDGameFixRunner.run(list, setting)
    check(out.done == 0 && read(docs.appendingPathComponent("My Games/Foo/foo.ini")) == iniBefore, "run again, nothing changes", "\(out.lines)")
    // A change of the player's in the game's own file is put back by `always`, and `missing` leaves it.
    write(drive.appendingPathComponent("Games/Foo/autoexec.cfg"), "mine\n")
    out = BCDGameFixRunner.run(fixes(["write \"%GAME%\\autoexec.cfg\" missing \"x\""]), setting)
    check(read(drive.appendingPathComponent("Games/Foo/autoexec.cfg")) == "mine\n", "missing leaves a file that is there")
    out = BCDGameFixRunner.run(fixes(["write \"%GAME%\\autoexec.cfg\" always \"x\""]), setting)
    check(read(drive.appendingPathComponent("Games/Foo/autoexec.cfg")) == "x" && read(backups.appendingPathComponent("original/Games__Foo__autoexec.cfg")) == "mine\n",
          "always replaces it, and what was there is kept as the original")
    // A fix that is off does not run.
    var off = fixes(["write \"%GAME%\\off.txt\" always x"]); off[0].enabled = false
    out = BCDGameFixRunner.run(off, setting)
    check(!exists(drive.appendingPathComponent("Games/Foo/off.txt")), "a fix that is off does not run")
    // A program is not an ini file.
    write(drive.appendingPathComponent("Games/Foo/bin.cfg"), "MZ\u{90}\0\u{3}\0\0\0")
    out = BCDGameFixRunner.run(fixes(["ini \"%GAME%\\bin.cfg\" S K V"]), setting)
    check(out.failed == 1, "an ini fix on a program image fails", out.lines.joined(separator: "\n"))

    // redist: through the injected reader
    var dll = Data([0x4D, 0x5A]); dll.append(Data(repeating: 7, count: 2000))
    setting.extractMember = { source, member in
        guard source.lastPathComponent == "dx.cab", member == "xinput1_3.dll" else { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such member"]) }
        return dll
    }
    write(drive.appendingPathComponent("Games/Foo/redist/dx.cab"), "cab")
    out = BCDGameFixRunner.run(fixes(["redist \"%GAME%\\redist\\dx.cab\" xinput1_3.dll \"%GAME%\\\""]), setting)
    check((try? Data(contentsOf: drive.appendingPathComponent("Games/Foo/xinput1_3.dll"))) == dll, "a DLL is taken out of the redistributable into the game's folder", out.lines.joined(separator: "\n"))
    out = BCDGameFixRunner.run(fixes(["redist \"%GAME%\\redist\\dx.cab\" xinput1_3.dll \"%GAME%\\\""]), setting)
    check(out.done == 0 && out.failed == 0, "and again: nothing")
    out = BCDGameFixRunner.run(fixes(["redist \"%GAME%\\redist\\dx.cab\" nothere.dll \"%GAME%\\bin\\\""]), setting)
    check(out.failed == 1 && !exists(drive.appendingPathComponent("Games/Foo/bin/nothere.dll")), "a member that is not there fails and writes nothing", out.lines.joined(separator: "\n"))
    out = BCDGameFixRunner.run(fixes(["redist \"%GAME%\\redist\\dx.cab\" xinput1_3.dll \"%DOCUMENTS%\\\""]), setting)
    check(out.failed == 1, "a DLL does not go outside the game's folder")
    setting.extractMember = { _, _ in Data([1, 2, 3]) }
    try? fm.removeItem(at: drive.appendingPathComponent("Games/Foo/xinput1_3.dll"))
    out = BCDGameFixRunner.run(fixes(["redist \"%GAME%\\redist\\dx.cab\" xinput1_3.dll \"%GAME%\\\""]), setting)
    check(out.failed == 1 && !exists(drive.appendingPathComponent("Games/Foo/xinput1_3.dll")), "bytes that are not a DLL are not written")
    check(fm.fileExists(atPath: backups.path) && !(try! fm.contentsOfDirectory(atPath: drive.appendingPathComponent("Games/Foo").path)).contains { $0.hasSuffix(".bcd-part") },
          "no half-written part file is left in the game's folder")
}

// ------------------------------------------------------------------------------ saves outside the prefix
do {
    let base = scratch.appendingPathComponent("container-a")
    let docs = base.appendingPathComponent("Documents")
    let drive = docs.appendingPathComponent("wine/drive_c")
    let saves = BCDSaveRedirect.folder(documents: docs)
    func root(_ path: String, file: Bool = false) -> GameSaveRoot { GameSaveRoot(path: path, isFile: file, source: .played) }
    write(drive.appendingPathComponent("users/mythic/Documents/My Games/Foo/slot1.sav"), "one")
    write(drive.appendingPathComponent("users/mythic/Documents/My Games/Foo/sub/slot2.sav"), "two")
    write(drive.appendingPathComponent("users/mythic/AppData/Roaming/Vendor/Foo/p.cfg"), "cfg")
    let docRoot = root("users/mythic/Documents/My Games/Foo"), appRoot = root("users/mythic/AppData/Roaming/Vendor/Foo")

    check(BCDSaveRedirect.isEligible(docRoot) && BCDSaveRedirect.isEligible(appRoot), "folders under Documents and AppData are eligible")
    check(!BCDSaveRedirect.isEligible(root("users/mythic/Documents")) && !BCDSaveRedirect.isEligible(root("users/mythic/AppData/Roaming"))
          && !BCDSaveRedirect.isEligible(root("users/mythic/Documents/a.sav", file: true)) && !BCDSaveRedirect.isEligible(root("Games/Foo/saves"))
          && !BCDSaveRedirect.isEligible(root("users/Public/Documents/Foo")) && !BCDSaveRedirect.isEligible(root("windows/system32/x")) && !BCDSaveRedirect.isEligible(root("ProgramData/Foo")),
          "a profile folder itself, a file, the game's own folder, Public, Windows and ProgramData are not")
    check(BCDSaveRedirect.placeName(docRoot) == "Documents - My Games - Foo" && !BCDSaveRedirect.placeName(appRoot).contains("mythic"), "the place's name is how the player reads it, without the Windows user")

    check(BCDSaveRedirect.state(of: docRoot, game: "Foo", drive: drive, folder: saves) == .inPrefix, "before: in the prefix")
    let moved = try? BCDSaveRedirect.redirect(docRoot, game: "Foo", drive: drive, folder: saves)
    check(moved?.files == 2 && moved?.bytes == 6, "the folder moves: its files are counted", "\(String(describing: moved))")
    let link = drive.appendingPathComponent("users/mythic/Documents/My Games/Foo")
    check((try? fm.destinationOfSymbolicLink(atPath: link.path))?.hasPrefix("/") == false, "the link is relative (the container's path can change)", (try? fm.destinationOfSymbolicLink(atPath: link.path)) ?? "no link")
    check(read(link.appendingPathComponent("slot1.sav")) == "one" && read(link.appendingPathComponent("sub/slot2.sav")) == "two", "the game reads the same path as before")
    check(read(saves.appendingPathComponent("Foo/Documents - My Games - Foo/slot1.sav")) == "one", "and the files are in Game Saves, where Files shows them")
    write(link.appendingPathComponent("slot3.sav"), "three")
    check(read(saves.appendingPathComponent("Foo/Documents - My Games - Foo/slot3.sav")) == "three", "a file the game writes lands in Game Saves")
    check(BCDSaveRedirect.state(of: docRoot, game: "Foo", drive: drive, folder: saves) == .redirected(place: "Foo/Documents - My Games - Foo"), "state: redirected")
    check((try? BCDSaveRedirect.redirect(docRoot, game: "Foo", drive: drive, folder: saves)) == nil, "a second move of the same folder is refused")
    check((try? BCDSaveRedirect.redirect(root("users/mythic/Documents"), game: "Foo", drive: drive, folder: saves)) == nil, "a profile folder is refused")
    _ = try? BCDSaveRedirect.redirect(appRoot, game: "Foo", drive: drive, folder: saves)
    check(BCDSaveRedirect.records(in: saves).count == 2, "two records")

    // The container moves (reinstall, restore to another phone): the relative links still work.
    let moved2 = scratch.appendingPathComponent("container-b")
    try? fm.moveItem(at: base, to: moved2)
    let link2 = moved2.appendingPathComponent("Documents/wine/drive_c/users/mythic/Documents/My Games/Foo/slot1.sav")
    check(read(link2) == "one", "after the whole container moved, the link still reaches the files")
    try? fm.moveItem(at: moved2, to: base)

    // The prefix is reset: the link is gone, the saves are not; the next start makes the link again.
    try? fm.removeItem(at: drive.appendingPathComponent("users"))
    check(BCDSaveRedirect.state(of: docRoot, game: "Foo", drive: drive, folder: saves) == .needsLink(place: "Foo/Documents - My Games - Foo"), "state after a prefix reset: needs its link")
    let lines = BCDSaveRedirect.repair(game: "Foo", drive: drive, folder: saves)
    check(lines.count == 1 && lines[0].contains("2 save folders") && !lines[0].contains("mythic"), "repair makes both links again and logs counts only", "\(lines)")
    check(read(link.appendingPathComponent("sub/slot2.sav")) == "two", "and the game finds its saves again")
    check(BCDSaveRedirect.repair(game: "Foo", drive: drive, folder: saves).isEmpty, "repair again: nothing to do")
    check(BCDSaveRedirect.repair(game: "Other", drive: drive, folder: saves).isEmpty, "another game's records are not touched")

    // Back into the prefix.
    check((try? BCDSaveRedirect.restore(docRoot, game: "Foo", drive: drive, folder: saves)) != nil, "restore moves the folder back")
    var isDir: ObjCBool = false
    check(fm.fileExists(atPath: link.path, isDirectory: &isDir) && isDir.boolValue && (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil, "it is a real folder again")
    check(read(link.appendingPathComponent("slot3.sav")) == "three" && !exists(saves.appendingPathComponent("Foo/Documents - My Games - Foo")), "with what the game wrote, and nothing left behind")
    check(BCDSaveRedirect.records(in: saves).count == 1, "the record goes")
    check((try? BCDSaveRedirect.restore(docRoot, game: "Foo", drive: drive, folder: saves)) == nil, "restoring what is not moved fails")

    // The game made a folder of its own where the link was: neither is touched.
    try? fm.removeItem(at: drive.appendingPathComponent("users/mythic/AppData/Roaming/Vendor/Foo"))
    write(drive.appendingPathComponent("users/mythic/AppData/Roaming/Vendor/Foo/new.cfg"), "new")
    check((try? BCDSaveRedirect.restore(appRoot, game: "Foo", drive: drive, folder: saves)) == nil
          && read(drive.appendingPathComponent("users/mythic/AppData/Roaming/Vendor/Foo/new.cfg")) == "new"
          && exists(saves.appendingPathComponent("Foo/AppData - Roaming - Vendor - Foo/p.cfg")), "a folder of the game's own blocks the move back; both stay")
    check(BCDSaveRedirect.state(of: appRoot, game: "Foo", drive: drive, folder: saves) == .inPrefix, "and the prefix's own folder reads as in the prefix")
    // A name taken in Game Saves gets a number.
    write(saves.appendingPathComponent("Bar/Documents - My Games - Foo/x"), "x")
    write(drive.appendingPathComponent("users/mythic/Documents/My Games/Foo/y.sav"), "y")
    try? fm.removeItem(at: saves.appendingPathComponent("Foo/Documents - My Games - Foo"))
    let again = try? BCDSaveRedirect.redirect(docRoot, game: "Bar", drive: drive, folder: saves)
    check(again?.place == "Bar/Documents - My Games - Foo 2" && read(saves.appendingPathComponent("Bar/Documents - My Games - Foo/x")) == "x", "a taken name gets a number and nothing in it is touched", "\(String(describing: again))")
    // The record is by the game's key; the folder carries the title, whatever characters it has.
    write(drive.appendingPathComponent("users/mythic/Documents/Other/o.sav"), "o")
    let keyed = try? BCDSaveRedirect.redirect(root("users/mythic/Documents/Other"), game: "c:\\games\\cool\\cool.exe", title: "Cool: Game?", drive: drive, folder: saves)
    check(keyed?.place == "Cool- Game-/Documents - Other" && BCDSaveRedirect.records(in: saves).contains { $0.game == "c:\\games\\cool\\cool.exe" && $0.title == "Cool: Game?" },
          "the record is by the game's key and the folder has the title with unusable characters made safe", "\(String(describing: keyed))")
    check(BCDSaveRedirect.state(of: root("users/mythic/Documents/Other"), game: "c:\\games\\cool\\cool.exe", drive: drive, folder: saves) == .redirected(place: "Cool- Game-/Documents - Other"), "and it is found again by the key (a rename of the game does not lose it)")
}

// ------------------------------------------------------------------------------ the prefix kit
do {
    let root = scratch.appendingPathComponent("kit")
    let prefix = root.appendingPathComponent("Documents/wine")
    let drive = prefix.appendingPathComponent("drive_c")
    let copies = root.appendingPathComponent("Documents/Prefix Copies")
    func build() {
        try? fm.removeItem(at: prefix)
        for (name, text) in [("system.reg", "SYSTEM v1"), ("user.reg", "USER v1"), ("userdef.reg", "DEF v1"), (".update-timestamp", "123"), (BCDRegistryEdit.stateName, "{}")] { write(prefix.appendingPathComponent(name), text) }
        write(drive.appendingPathComponent("users/mythic/Documents/My Games/Foo/a.sav"), "save-a")
        write(drive.appendingPathComponent("users/mythic/AppData/Local/Foo/cfg.ini"), "cfg")
        write(drive.appendingPathComponent("users/mythic/AppData/Local/Foo/Cache/big.bin"), "cache")
        write(drive.appendingPathComponent("users/mythic/AppData/Local/Temp/junk.dat"), "junk")
        write(drive.appendingPathComponent("users/mythic/AppData/Local/Foo/run.log"), "log")
        write(drive.appendingPathComponent("users/Public/Documents/p.txt"), "pub")
        write(drive.appendingPathComponent("ProgramData/Foo/data.bin"), "pd")
        write(drive.appendingPathComponent("windows/win.ini"), "[a]\nk=v\n")
        write(drive.appendingPathComponent("Games/Big/game.exe"), "MZ")
        write(drive.appendingPathComponent("External/ssd.bin"), "ssd")
    }
    build()
    let listing = BCDPrefixKit.list(prefix: prefix)
    let paths = Set(listing.files.map(\.path))
    check(paths == ["system.reg", "user.reg", "userdef.reg", ".update-timestamp", ".bcd-setup-state.json", "drive_c/users/mythic/Documents/My Games/Foo/a.sav",
                    "drive_c/users/mythic/AppData/Local/Foo/cfg.ini", "drive_c/users/Public/Documents/p.txt", "drive_c/ProgramData/Foo/data.bin"],
          "the kit: registry, users, ProgramData; no cache, temp, log, Windows, game or external file", "\(paths.sorted())")
    check(BCDPrefixKit.users(prefix: prefix) == ["mythic"], "the Windows user")

    // A save folder moved to Game Saves is a link.
    let saves = root.appendingPathComponent("Documents/Game Saves")
    let moved = try? BCDSaveRedirect.redirect(GameSaveRoot(path: "users/mythic/Documents/My Games/Foo", isFile: false, source: .played), game: "Foo", drive: drive, folder: saves)
    check(moved != nil, "(a save folder is moved out of the prefix)")
    let withLink = BCDPrefixKit.list(prefix: prefix)
    check(withLink.links == ["drive_c/users/mythic/Documents/My Games/Foo"] && !withLink.files.contains { $0.path.contains("a.sav") }, "a link is listed as a link, its files are not the prefix's")

    // Copies
    let made = try? BCDPrefixKit.makeCopy(prefix: prefix, into: copies, name: "2026-10-25 14.32.07")
    check(made?.files == 8 && made?.copy.name == "2026-10-25 14.32.07", "a copy of the kit is made", "\(String(describing: made))")
    check(read(copies.appendingPathComponent("2026-10-25 14.32.07/user.reg")) == "USER v1" && read(copies.appendingPathComponent("2026-10-25 14.32.07/drive_c/ProgramData/Foo/data.bin")) == "pd", "with the files")
    check((try? fm.destinationOfSymbolicLink(atPath: copies.appendingPathComponent("2026-10-25 14.32.07/drive_c/users/mythic/Documents/My Games/Foo").path)) != nil, "and the link as a link")
    check(!exists(copies.appendingPathComponent("2026-10-25 14.32.07/drive_c/Games")) && !exists(copies.appendingPathComponent("2026-10-25 14.32.07/drive_c/windows")), "no game and no Windows file")
    check(BCDPrefixKit.copies(in: copies).map(\.name) == ["2026-10-25 14.32.07"] && !(try! fm.contentsOfDirectory(atPath: copies.path)).contains { $0.hasPrefix(".partial") }, "the copy is listed, no partial folder is left")
    let second = try? BCDPrefixKit.makeCopy(prefix: prefix, into: copies, name: "2026-10-25 14.32.07")
    check(second?.copy.name == "2026-10-25 14.32.07 2", "a name taken gets a number")

    // Change the prefix, put the first copy back.
    write(prefix.appendingPathComponent("user.reg"), "USER v2")
    write(drive.appendingPathComponent("ProgramData/Extra/new.bin"), "new")
    try? fm.removeItem(at: drive.appendingPathComponent("ProgramData/Foo/data.bin"))
    let back = try? BCDPrefixKit.putBack(copies.appendingPathComponent("2026-10-25 14.32.07"), prefix: prefix)
    check(back == 8 && read(prefix.appendingPathComponent("user.reg")) == "USER v1" && read(drive.appendingPathComponent("ProgramData/Foo/data.bin")) == "pd", "putting a copy back restores the files", "\(String(describing: back))")
    check(read(drive.appendingPathComponent("ProgramData/Extra/new.bin")) == "new" && read(drive.appendingPathComponent("Games/Big/game.exe")) == "MZ" && read(drive.appendingPathComponent("windows/win.ini")) == "[a]\nk=v\n",
          "files that are not in the copy, the games and Windows' own are not touched")
    check((try? BCDPrefixKit.putBack(root, prefix: prefix)) == nil, "a folder that is not a copy is refused")

    // Zip
    let zipURL = root.appendingPathComponent("Documents/Prefix Exports/2026-10-25 15.00.00 Prefix.zip")
    let exported = try? BCDPrefixKit.exportZip(prefix: prefix, to: zipURL)
    check(exported?.files == 9 && exported?.links == 1 && exists(zipURL), "an export holds the files and counts the link it leaves out", "\(String(describing: exported))")
    let info = try? BCDPrefixKit.inspect(zip: zipURL)
    check(info?.users == ["mythic"] && info?.files == 9 && info?.made.hasSuffix("Z") == true, "an export says its users and files before anything is written", "\(String(describing: info))")
    let fresh = root.appendingPathComponent("fresh/wine")
    try? fm.createDirectory(at: fresh.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    let imported = try? BCDPrefixKit.importZip(zipURL, prefix: fresh)
    check(imported?.written == 9 && imported?.refused == 0 && read(fresh.appendingPathComponent("system.reg")) == "SYSTEM v1" && read(fresh.appendingPathComponent("drive_c/users/mythic/AppData/Local/Foo/cfg.ini")) == "cfg",
          "an import writes the kit into another prefix", "\(String(describing: imported))")
    // A hostile zip: names above the prefix, absolute, other folders; and one that is not ours.
    let hostile = root.appendingPathComponent("hostile.zip")
    let hz = try! SaveZipWriter(url: hostile)
    for name in ["../escape.txt", "/abs.txt", "drive_c/Games/Big/game.exe", "drive_c/windows/win.ini", "drive_c/users/../../up.txt", "drive_c/users/mythic/Documents/ok.sav", "user.reg", "other.reg", "drive_c/users/C:/x"] {
        try! hz.add(name: name, data: Data("x".utf8))
    }
    try! hz.add(name: BCDPrefixKit.manifestName, data: BCDPrefixKit.manifest(made: Date(), users: ["mythic"]))
    try! hz.finish()
    let target = root.appendingPathComponent("target/wine")
    try? fm.createDirectory(at: target.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    let hostileResult = try? BCDPrefixKit.importZip(hostile, prefix: target)
    check(hostileResult?.written == 2 && hostileResult?.refused == 7, "a hostile zip: two good entries written, seven refused", "\(String(describing: hostileResult))")
    check(!exists(root.appendingPathComponent("target/escape.txt")) && !exists(root.appendingPathComponent("escape.txt")) && !exists(target.appendingPathComponent("drive_c/Games"))
          && !exists(target.appendingPathComponent("drive_c/windows")) && !exists(target.appendingPathComponent("other.reg")) && !exists(root.appendingPathComponent("up.txt")), "and nothing was written outside the kit")
    let plain = root.appendingPathComponent("plain.zip")
    let pz = try! SaveZipWriter(url: plain); try! pz.add(name: "user.reg", data: Data("x".utf8)); try! pz.finish()
    check((try? BCDPrefixKit.importZip(plain, prefix: target)) == nil && (try? BCDPrefixKit.inspect(zip: plain)) == nil, "a zip without BCD's manifest is refused")

    // Reconfigure
    build()
    let template = root.appendingPathComponent("template/prefix")
    for (name, text) in [("system.reg", "SYSTEM template"), ("user.reg", "USER template"), ("userdef.reg", "DEF template")] { write(template.appendingPathComponent(name), text) }
    try? BCDPrefixKit.reconfigure(prefix: prefix, template: template, templateUser: "mythic")
    check(read(prefix.appendingPathComponent("user.reg")) == "USER template" && read(prefix.appendingPathComponent("system.reg")) == "SYSTEM template" && !exists(prefix.appendingPathComponent(BCDRegistryEdit.stateName))
          && read(drive.appendingPathComponent("users/mythic/Documents/My Games/Foo/a.sav")) == "save-a" && read(prefix.appendingPathComponent(".update-timestamp")) == "123", "reconfigure: the template's registry, the setup's state gone, saves and the stamp stay")
    build()
    write(drive.appendingPathComponent("users/madeira/Documents/old.sav"), "old")
    check((try? BCDPrefixKit.reconfigure(prefix: prefix, template: template, templateUser: "mythic")) == nil && read(prefix.appendingPathComponent("user.reg")) == "USER v1",
          "reconfigure refuses a prefix whose Windows user is another one, and changes nothing")
    check((try? BCDPrefixKit.reconfigure(prefix: prefix, template: root, templateUser: "madeira")) == nil, "reconfigure refuses a template that has no registry")

    // System files
    let tw = root.appendingPathComponent("template2/prefix/drive_c/windows")
    write(tw.appendingPathComponent("inf/a.inf"), "inf-a")
    write(tw.appendingPathComponent("win.ini"), "TEMPLATE")
    write(tw.appendingPathComponent("Fonts/f.ttf"), "font")
    write(tw.appendingPathComponent("system.ini"), "TEMPLATE-SYS")
    build()
    write(drive.appendingPathComponent("windows/system.ini"), "")
    let putFiles = try? BCDPrefixKit.reinstallSystemFiles(prefix: prefix, template: root.appendingPathComponent("template2/prefix"))
    check(putFiles == 3 && read(drive.appendingPathComponent("windows/inf/a.inf")) == "inf-a" && read(drive.appendingPathComponent("windows/Fonts/f.ttf")) == "font" && read(drive.appendingPathComponent("windows/system.ini")) == "TEMPLATE-SYS",
          "system files: what is missing or empty comes back", "\(String(describing: putFiles))")
    check(read(drive.appendingPathComponent("windows/win.ini")) == "[a]\nk=v\n", "a win.ini with content (games keep settings there) is not replaced")
}

// ------------------------------------------------------------------------------ a wallpaper
do {
    // A 40 x 20 picture, red on top and blue below, as a PNG.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 10, width: 40, height: 10))   // user space: y up, so this is the top
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    let picture = scratch.appendingPathComponent("wall.png")
    try? (png as Data).write(to: picture)
    let bmp = BCDWallpaper.bmp(from: picture, width: 32, height: 24)
    check(bmp != nil && bmp![0] == 0x42 && bmp![1] == 0x4D, "a picture becomes a .bmp")
    if let bmp {
        func u32(_ o: Int) -> Int { Int(bmp[o]) | Int(bmp[o + 1]) << 8 | Int(bmp[o + 2]) << 16 | Int(bmp[o + 3]) << 24 }
        check(u32(2) == bmp.count && u32(10) == 54 && u32(14) == 40 && u32(18) == 32 && u32(22) == 24 && Int(bmp[28]) == 24 && u32(30) == 0, "the headers: size, offset, 32 x 24, 24 bits, no compression")
        check(bmp.count == 54 + ((32 * 3 + 3) & ~3) * 24, "rows padded to four bytes")
        // Fill: the picture (2:1) covers 32 x 24 with its middle kept; the first stored row is the bottom: blue, as BGR bytes.
        check(bmp[54] > 200 && bmp[56] < 80, "the bottom row is stored first: blue (B high, R low; the picture is scaled, so not exact)", "\(Array(bmp[54..<57]))")
        let last = 54 + ((32 * 3 + 3) & ~3) * 23
        check(bmp[last] < 80 && bmp[last + 2] > 200, "the top row is stored last: red", "\(Array(bmp[last..<(last + 3)]))")
    }
    check(BCDWallpaper.bmp(from: scratch.appendingPathComponent("nothere.png"), width: 32, height: 24) == nil && BCDWallpaper.bmp(from: picture, width: 0, height: 24) == nil
          && BCDWallpaper.bmp(from: picture, width: 9000, height: 24) == nil, "a missing file and impossible sizes make nothing")
    check(BCDWallpaper.size("1408x648")?.width == 1408 && BCDWallpaper.size("1408x648")?.height == 648 && BCDWallpaper.size("100x100") == nil && BCDWallpaper.size("abc") == nil, "the desktop's size from a Resolution value")
}

// ------------------------------------------------------------------------------ icons of programs
do {
    for path in programs {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard let found = BCDExeIcon.find(at: URL(fileURLWithPath: path)) else { check(false, "\(name) has an icon BCD finds"); continue }
        check(found.ico.starts(with: [0, 0, 1, 0, 1, 0]) && found.width >= 16 && found.width <= 256, "\(name): a one-picture .ico of \(found.width) pixels (\(found.isPNG ? "PNG" : "bitmap"))")
        let source = CGImageSourceCreateWithData(found.ico as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(image?.width == found.width && image?.height == found.height, "\(name): ImageIO reads the .ico at the size the group says", "\(image?.width ?? -1)")
        let cover = BCDExeIconCover.png(fromICO: found.ico)
        let decoded = cover.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(decoded?.width == BCDExeIconCover.width && decoded?.height == BCDExeIconCover.height, "\(name): the cover is \(BCDExeIconCover.width) x \(BCDExeIconCover.height)")
    }
    // A program with no resources, and things that are not programs
    let flat = scratch.appendingPathComponent("flat.exe")
    if let first = programs.first, var data = try? Data(contentsOf: URL(fileURLWithPath: first)) {
        // The same program with its resource directory entry zeroed: no icon.
        let pe = Int(data[0x3C]) | Int(data[0x3D]) << 8
        let magic = Int(data[pe + 24]) | Int(data[pe + 25]) << 8
        let dir = pe + 24 + (magic == 0x20B ? 112 : 96) + 2 * 8
        for i in 0..<8 { data[dir + i] = 0 }
        try? data.write(to: flat)
        check(BCDExeIcon.find(at: flat) == nil, "a program with no resource directory has no icon")
        // Cut short anywhere: never a crash.
        var survived = true
        for cut in stride(from: 0x80, to: min(data.count, 60_000), by: 997) { _ = BCDExeIcon.find(in: data.prefix(cut)); survived = survived && true }
        check(survived, "a program cut short at many places is read without a crash")
        // Damaged: random bytes in the first 40 KB of the real one.
        var damaged = (try? Data(contentsOf: URL(fileURLWithPath: first))) ?? Data()
        var seed: UInt64 = 12345
        for _ in 0..<4000 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; let at = Int(seed >> 33) % min(damaged.count, 1 << 20); damaged[at] = UInt8(truncatingIfNeeded: seed >> 20) }
        _ = BCDExeIcon.find(in: damaged)
        check(true, "a program with 4000 damaged bytes is read without a crash")
    }
    check(BCDExeIcon.find(in: Data("not a program at all, just text".utf8)) == nil && BCDExeIcon.find(in: Data()) == nil, "text and nothing are not programs")
    check(BCDExeIconCover.png(fromICO: Data([0, 0, 1, 0, 1, 0, 16, 16])) == nil, "a broken .ico makes no cover")
}

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
