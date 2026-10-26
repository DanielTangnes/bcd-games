// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// The Steam game language (SteamLanguage and the depot selection in SteamAppInfo.swift, the install record in
// AppManifestWriter.swift / SteamInstall.swift, the DLC wrapper in BCDSteamDLC.swift), compiled and run by
// tests/host/check-steam-language.py. Fixtures are synthetic: no Steam, no network.

import Foundation

// ---- stand-ins for what the app provides -------------------------------------------------------------
enum SteamLog {
    static func event(_ m: String) {}
    static func trace(_ m: @autoclosure () -> String) {}
}
nonisolated(unsafe) var configValues: [String: String] = [:]
enum MadeiraConfig {
    static func get(_ key: String) -> String? { configValues[key] }
    @discardableResult static func set(_ key: String, _ value: String?) -> Bool { configValues[key] = value; return true }
}

var failures = 0
func check(_ what: String, _ ok: Bool, _ detail: Any = "") {
    print((ok ? "ok   " : "FAIL ") + what + (ok ? "" : "\n     \(detail)"))
    if !ok { failures += 1 }
}
func ids(_ depots: [SteamAppInfo.DepotInfo]) -> [UInt32] { depots.map(\.depotID) }
func appVDF(_ body: String) -> Data { Data(("\"appinfo\" { " + body + " }").utf8) }

let game = SteamAppInfo.parse(appID: 11, from: appVDF(#"""
"common" { "name" "Lang" "type" "game" "oslist" "windows"
  "supported_languages" { "english" { "supported" "true" } "german" { "supported" "true" "full_audio" "true" } "japanese" { "supported" "true" } "french" { "supported" "false" } } }
"config" { "installdir" "Lang" }
"depots" {
  "301" { "config" { "oslist" "windows" } "manifests" { "public" { "gid" "3001" "size" "500" "download" "200" } } }
  "302" { "config" { "oslist" "windows" "language" "english" } "manifests" { "public" { "gid" "3002" "size" "0" "download" "50" } } }
  "303" { "config" { "oslist" "windows" "language" "german" } "manifests" { "public" { "gid" "3003" "size" "40" "download" "20" } } }
  "401" { "config" { "oslist" "windows" } "dlcappid" "9001" "manifests" { "public" { "gid" "4001" "size" "10" "download" "5" } } }
  "402" { "config" { "oslist" "windows" "language" "english" } "dlcappid" "9001" "manifests" { "public" { "gid" "4002" "size" "10" "download" "5" } } }
  "403" { "config" { "oslist" "windows" "language" "german" } "dlcappid" "9001" "manifests" { "public" { "gid" "4003" "size" "10" "download" "5" } } }
}
"""#))!

// ---- 1. by default nothing changes: English ------------------------------------------------------------------
check("nothing set: the language is English", SteamLanguage.chosen == nil && SteamLanguage.download == "english" && SteamLanguage.download(for: 11) == "english")
check("  the same depots as always (common and English; no DLC, no German)", ids(game.installDepots()) == [301, 302], ids(game.installDepots()))
check("  explicit English gives the same list", ids(game.installDepots(language: "english")) == ids(game.installDepots()))
check("  the depot language and the record's language are English", game.depotLanguage == "english" && game.gameLanguage == "english")
check("  the DLC wrapper takes the English DLC depots", ids(game.installDepots(including: [9001])) == [301, 302, 401, 402], ids(game.installDepots(including: [9001])))
check("  the log summary says the same: German is out by the language rule, English is in",
      game.depotSelectionSummary().contains("303[-]lang") && game.depotSelectionSummary().contains("302[-]sel"), game.depotSelectionSummary())
check("supported languages are read without the unsupported ones", game.languages == ["english", "german", "japanese"], game.languages.sorted())

// ---- 2. the sizes ---------------------------------------------------------------------------------------------
check("download size counts the selected depots", game.downloadSize(for: "windows") == 250, game.downloadSize(for: "windows"))
check("the installed size: manifests.public.size, else the download figure", game.installSize(for: "windows") == 550, game.installSize(for: "windows"))

// ---- 3. the install record --------------------------------------------------------------------------------------
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("steam-lang-\(getpid())", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
func writeRecord(_ appID: UInt32, language: String?) -> String {
    let depots = [AppManifestWriter.InstalledDepot(depotID: 301, manifestGID: 3001, size: 500), AppManifestWriter.InstalledDepot(depotID: 302, manifestGID: 3002, size: 0)]
    if let language {
        try! AppManifestWriter.writeManifest(appID: appID, name: "Lang", installDir: "Lang", buildID: 5, steamID: 76561198000000001,
                                             sizeOnDisk: 500, steamAppsPath: tmp.path, installedDepots: depots, language: language)
    } else {
        try! AppManifestWriter.writeManifest(appID: appID, name: "Lang", installDir: "Lang", buildID: 5, steamID: 76561198000000001,
                                             sizeOnDisk: 500, steamAppsPath: tmp.path, installedDepots: depots)
    }
    return (try? String(contentsOf: tmp.appendingPathComponent("appmanifest_\(appID).acf"), encoding: .utf8)) ?? ""
}
let plain = writeRecord(11, language: nil)
check("a record written without a language says English in UserConfig and MountedConfig",
      plain.components(separatedBy: "\"language\"\t\t\"english\"").count == 3, plain)
check("  and it reads back", SteamInstallFiles.language(appID: 11, steamApps: tmp) == "english"
      && SteamInstallFiles.depots(appID: 11, steamApps: tmp) == [301, 302])
let japanese = writeRecord(12, language: "japanese")
check("a record written for Japanese says so in both blocks", japanese.components(separatedBy: "\"language\"\t\t\"japanese\"").count == 3
      && !japanese.contains("\"english\""))
check("  and it reads back", SteamInstallFiles.language(appID: 12, steamApps: tmp) == "japanese")
try? FileManager.default.removeItem(at: tmp)

// ---- 4. choosing a language ---------------------------------------------------------------------------------
SteamLanguage.choose("german")
check("German chosen: the German depots, and the record names German", ids(game.installDepots()) == [301, 303] && game.gameLanguage == "german"
      && SteamLanguage.chosen == "german", ids(game.installDepots()))
check("  the DLC wrapper follows (the German DLC depot, not the English one)", ids(game.installDepots(including: [9001])) == [301, 303, 401, 403],
      ids(game.installDepots(including: [9001])))
SteamLanguage.choose("japanese")
check("Japanese (supported, no depots): English depots, the record names Japanese", ids(game.installDepots()) == [301, 302] && game.depotLanguage == "english"
      && game.gameLanguage == "japanese")
SteamLanguage.choose("french")
check("a language the game lacks falls back to English", ids(game.installDepots()) == [301, 302] && game.gameLanguage == "english")
SteamLanguage.chooseForGame(11, "german")
check("a game's own choice wins over the setting, for that game only", ids(game.installDepots()) == [301, 303]
      && SteamLanguage.download(for: 12) == "french" && SteamLanguage.gameChoice(11) == "german")
SteamLanguage.chooseForGame(11, nil)
check("  and Default gives the setting back", SteamLanguage.gameChoice(11) == nil && SteamLanguage.download(for: 11) == "french")
SteamLanguage.choose(nil)
check("choosing nothing returns to English", SteamLanguage.chosen == nil && SteamLanguage.download == "english" && ids(game.installDepots()) == [301, 302])
configValues[SteamLanguage.configKey] = "klingon"
check("a value that is no Steam language counts as not set", SteamLanguage.chosen == nil && SteamLanguage.download == "english")
configValues[SteamLanguage.configKey] = nil

// ---- 5. the device's language, only when asked ---------------------------------------------------------------
SteamLanguage.choose(SteamLanguage.deviceChoice)
check("'device' follows the device's language", SteamLanguage.chosen == "device" && SteamLanguage.download == SteamLanguage.device)
SteamLanguage.choose(nil)
check("device languages map to Steam API language names",
      SteamLanguage.steamName(Locale(identifier: "ja_JP")) == "japanese" && SteamLanguage.steamName(Locale(identifier: "zh-Hant-TW")) == "tchinese"
      && SteamLanguage.steamName(Locale(identifier: "zh-Hans-CN")) == "schinese" && SteamLanguage.steamName(Locale(identifier: "pt_BR")) == "brazilian"
      && SteamLanguage.steamName(Locale(identifier: "pt_PT")) == "portuguese" && SteamLanguage.steamName(Locale(identifier: "es_MX")) == "latam"
      && SteamLanguage.steamName(Locale(identifier: "es_ES")) == "spanish" && SteamLanguage.steamName(Locale(identifier: "ko_KR")) == "koreana"
      && SteamLanguage.steamName(Locale(identifier: "tr_TR")) == "turkish" && SteamLanguage.steamName(Locale(identifier: "xx_XX")) == nil)
check("every language code has a name of its own", SteamLanguage.all.count == 30 && Set(SteamLanguage.all.map(\.code)).count == 30
      && SteamLanguage.name("turkish") == "Türkçe" && SteamLanguage.name("unknown") == "Unknown")

exit(failures == 0 ? 0 : 1)
