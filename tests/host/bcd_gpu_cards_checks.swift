// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

// The behaviour half of tests/host/check-gpu-cards.py. That script compiles this file as main.swift together with
// app/Madeira/BCDGPUCards.swift (plain Foundation) and runs it: the cards, the DXMT options and environment a card
// makes, and how they join a launch's own DXMT options.
import Foundation

var failures = 0
func require(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("PASS: " + what) } else { print("FAIL: " + what); failures += 1 }
}

let cards = BCDGPUCards.cards
require(Set(cards.map(\.id)).count == cards.count, "every card has its own id")
require(Set(cards.map { "\($0.vendor):\($0.device)" }).count == cards.count, "every card has its own PCI pair")
require(cards.allSatisfy { !$0.name.isEmpty && $0.name.utf8.count < 100 && !$0.name.contains(";") && !$0.name.contains("\"") },
        "every name is short and has no ; or \" (DXMT's option separators)")
require(BCDGPUCards.card("nvidia").map { $0.vendor == 0x10DE && $0.device == 0x2544 && $0.name == "NVIDIA GeForce RTX 3060" } == true,
        "the nvidia card is the 10DE:2544 GeForce RTX 3060 the older switch reports")
require(BCDGPUCards.card("apple").map { $0.vendor == 0x106B && $0.device == 0x0001 && $0.isApple } == true, "the apple card is BCD's own 106B:0001")
require(BCDGPUCards.card("nope") == nil && BCDGPUCards.card("") == nil, "an unknown or empty id is no card")
require(BCDGPUCards.choices.first?.0 == "" && BCDGPUCards.choices.count == cards.count + 1, "the picker is the default, then every card")
require(BCDGPUCards.knownPairs.count == cards.count, "known pairs: one per card")

// DXMT's options
let nv = BCDGPUCards.card("nvidia")!
require(BCDGPUCards.dxmtOptions(nv) == [
    "dxgi.customVendorId=10de", "dxgi.customDeviceId=2544", "d3d9.customVendorId=10de", "d3d9.customDeviceId=2544",
    "dxgi.customDeviceDesc=\"NVIDIA GeForce RTX 3060\"", "d3d9.customDeviceDesc=\"NVIDIA GeForce RTX 3060\"",
], "the nvidia card's options: ids for DXGI and Direct3D 9, then the quoted names")
require(BCDGPUCards.dxmtOptions(nv, names: false).count == 4, "without names: four ids")
require(BCDGPUCards.dxmtOptions(BCDGPUCards.card("apple")!).isEmpty, "the apple card overrides nothing")
for card in cards {
    let line = BCDGPUCards.dxmtOptions(card).joined(separator: ";")
    require(line.utf16.count <= BCDGPUCards.dxmtConfigLimit, "\(card.id): its options fit DXMT's limit alone (\(line.utf16.count))")
    require(card.isApple || line.contains("customVendorId=\(card.vendorHex)") && line.contains("customDeviceId=\(card.deviceHex)"),
            "\(card.id): ids are four lower-case hex digits")
}
require(BCDGPUCards.isIdentityOption("dxgi.customDeviceId=2544") && BCDGPUCards.isIdentityOption("d3d9.customVendorId=10de")
        && BCDGPUCards.isIdentityOption("dxgi.customDeviceDesc=\"x y\""), "adapter options are recognised")
require(!BCDGPUCards.isIdentityOption("dxgi.forceSDR=True") && !BCDGPUCards.isIdentityOption("d3d11.metalSpatialUpscaleFactor=1.5")
        && !BCDGPUCards.isIdentityOption("d3d9.maxFrameLatency=1"), "other DXMT options are not")

// Joining a launch's options
let amd = BCDGPUCards.card("amd")!
let mine = BCDGPUCards.merged(["d3d11.metalSpatialUpscaleFactor=1.5", "dxgi.customDeviceId=2544", "d3d9.customDeviceDesc=\"Old\""], with: amd)
require(mine.options.first == "d3d11.metalSpatialUpscaleFactor=1.5", "the launch's other options stay, first")
require(mine.replaced == 2 && !mine.options.contains("dxgi.customDeviceId=2544") && !mine.options.contains("d3d9.customDeviceDesc=\"Old\""),
        "the older adapter options (the NVIDIA switch's, a game's own) are replaced")
require(Array(mine.options.dropFirst()) == BCDGPUCards.dxmtOptions(amd) && !mine.namesDropped, "the card's options follow")
let apple = BCDGPUCards.merged(["dxgi.customDeviceId=2544", "d3d11.x=1"], with: BCDGPUCards.card("apple")!)
require(apple.options == ["d3d11.x=1"] && apple.replaced == 1 && !apple.namesDropped, "the apple card takes the NVIDIA switch's id away and adds none")
let empty = BCDGPUCards.merged([], with: nv)
require(empty.options == BCDGPUCards.dxmtOptions(nv) && empty.replaced == 0, "with no options of its own a launch gets the card's")

let long = ["d3d11.longOptionOne=" + String(repeating: "a", count: 40), "d3d11.longOptionTwo=" + String(repeating: "b", count: 40)]
let tight = BCDGPUCards.merged(long, with: nv)
require(tight.namesDropped && !tight.options.contains { $0.contains("customDeviceDesc") }, "past DXMT's limit the names go first")
require(Array(tight.options.suffix(4)) == BCDGPUCards.dxmtOptions(nv, names: false), "... and the ids stay")
require(tight.options.joined(separator: ";").utf16.count <= BCDGPUCards.dxmtConfigLimit, "... which brings the whole under the limit: \(tight.options.joined(separator: ";").utf16.count)")
let fine = BCDGPUCards.merged(["d3d11.shortOption=1"], with: nv)
require(!fine.namesDropped && fine.options.joined(separator: ";").utf16.count <= BCDGPUCards.dxmtConfigLimit, "an ordinary launch keeps the names")

// The environment
let envNV = BCDGPUCards.environment(nv)
require(envNV.set["DXMT_ENABLE_NVEXT"] == "1" && envNV.set["DXMT_WSI_MONITOR_IDENTITY"] == "1" && envNV.set["DXMT_WSI_MODE_TABLE"] == "1",
        "an NVIDIA card turns the NVIDIA switches on, as the older switch does")
require(envNV.set["MADEIRA_GPU_VENDOR"] == "10de" && envNV.set["MADEIRA_GPU_DEVICE"] == "2544" && envNV.set["MADEIRA_GPU_NAME"] == "NVIDIA GeForce RTX 3060"
        && envNV.unset.isEmpty, "... and Windows gets its ids and name")
let envAMD = BCDGPUCards.environment(amd)
require(Set(envAMD.unset) == ["DXMT_ENABLE_NVEXT", "DXMT_WSI_MONITOR_IDENTITY", "DXMT_WSI_MODE_TABLE"] && envAMD.set["DXMT_ENABLE_NVEXT"] == nil,
        "another maker's card turns them off, which is how it wins over the older switch")
require(envAMD.set["MADEIRA_GPU_VENDOR"] == "1002" && envAMD.set["MADEIRA_GPU_DEVICE"] == "73df" && envAMD.set["MADEIRA_GPU_NAME"] == "AMD Radeon RX 6700 XT", "... and gets its own ids")
let envApple = BCDGPUCards.environment(BCDGPUCards.card("apple")!)
require(Set(envApple.unset) == ["DXMT_ENABLE_NVEXT", "DXMT_WSI_MONITOR_IDENTITY", "DXMT_WSI_MODE_TABLE", "MADEIRA_GPU_VENDOR", "MADEIRA_GPU_DEVICE", "MADEIRA_GPU_NAME"]
        && envApple.set.isEmpty, "the apple card without the Metal device's name unsets everything: BCD's own identity")
let envNative = BCDGPUCards.environment(BCDGPUCards.card("apple")!, nativeName: "Apple A17 Pro GPU")
require(envNative.set == ["MADEIRA_GPU_VENDOR": "106b", "MADEIRA_GPU_DEVICE": "0001", "MADEIRA_GPU_NAME": "Apple A17 Pro GPU"]
        && Set(envNative.unset) == ["DXMT_ENABLE_NVEXT", "DXMT_WSI_MONITOR_IDENTITY", "DXMT_WSI_MODE_TABLE"],
        "... with it, Windows says the Metal device's name at 106B:0001, and the NVIDIA switches are off")
require(BCDGPUCards.environment(BCDGPUCards.card("apple")!, nativeName: "").set.isEmpty, "an empty name is no name")
require(BCDGPUCards.environment(amd, nativeName: "Apple A17 Pro GPU").set["MADEIRA_GPU_NAME"] == "AMD Radeon RX 6700 XT",
        "another maker's card ignores the Metal name")

// Video memory
let labels = BCDGPUCards.memoryChoices([0, 512, 1024, 1536, 4352, 6144])
require(labels.map(\.0) == ["", "512", "1024", "1536", "4352", "6144"], "memory values are megabytes, empty for automatic")
require(labels.map(\.1) == ["Automatic", "0.5 GB", "1 GB", "1.5 GB", "4.25 GB", "6 GB"], "memory labels are worded as Settings words them: \(labels.map(\.1))")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures != 0 { exit(1) }
