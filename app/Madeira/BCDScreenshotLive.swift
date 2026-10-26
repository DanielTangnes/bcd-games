// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
import Photos
import UIKit
import os

// A screenshot of the game from the in-game menu (Tools › Take a screenshot), and its way to Send Log.
//
//  - The picture is the game's own surface (MetalHostView): the window of BCD's menu, HUD and touch controls is a different window,
//    so none of it is in the picture. It is drawn at most 2000 pixels on the long side, as a JPEG, and kept in Documents/Screenshots
//    (Files › BCD › Screenshots); with the switch on (the default) and the player's permission it is added to Photos too, add-only:
//    BCD never reads the photo library.
//  - It is drawn only when the app has 160 MB to spare, so a game close to iOS's limit is never asked for 10 MB more.
//  - Send Log offers to send the picture that belongs to the log being sent (BCDLogComment, LogUpload). What is sent is a separate small
//    copy of about 100 KB at most (BCDScreenshotShrink), made when the log goes; the picture kept here is not touched. It is sent as it
//    is, and the dialog says so.
//
// Left out of the preview build (tools/ui-preview.py, ENGINE_BOUND).

@MainActor enum BCDScreenshotLive {
    /// Settings › Logs (and the in-game menu): also add the picture to Photos. On unless turned off.
    static let photosKey = "madeira.bcd.screenshot.photos"
    static var toPhotos: Bool {
        get { UserDefaults.standard.object(forKey: photosKey) == nil || UserDefaults.standard.bool(forKey: photosKey) }
        set { UserDefaults.standard.set(newValue, forKey: photosKey) }
    }

    static var folder: URL? {
        MadeiraConfig.documents?.appendingPathComponent(BCDScreenshotRules.folder, isDirectory: true)
    }

    /// Once at start: Send Log's comment dialog learns to offer a picture.
    static func install() {
        BCDLogComment.screenshotFor = { log in candidate(for: log) }
        BCDLogComment.screenshotChosen = { log, shot in LogUpload.attach(shot, to: log) }
    }

    // MARK: Taking one

    /// The game's picture now. The result is said on the session line over the game and logged as [screenshot].
    static func take() {
        let model = LibraryModel.shared
        guard model.current != nil, !model.launching else { return }
        let host = MetalHostView.shared
        guard host.window != nil, host.bounds.width > 8, host.bounds.height > 8 else {
            say("The game has no picture to take yet.")
            return
        }
        let free = Int(os_proc_available_memory() >> 20)
        guard free >= BCDScreenshotRules.minFreeMB else {
            LogStore.shared.log("[screenshot] not taken: \(free) MB left, \(BCDScreenshotRules.minFreeMB) needed", level: .info)
            say("Not enough free memory to take a picture safely.")
            return
        }
        let scale = BCDScreenshotRules.scale(for: host.bounds.size, screenScale: host.window?.screen.scale ?? UIScreen.main.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        // The surface as the screen shows it, without the update that would wait for the game's next frame.
        let image = UIGraphicsImageRenderer(size: host.bounds.size, format: format).image { _ in
            drawn = host.drawHierarchy(in: host.bounds, afterScreenUpdates: false)
        }
        let black = !drawn || isBlack(image)
        let civil = BCDFormat.civil(Date())
        let name = BCDScreenshotRules.fileName(game: model.activeEntry?.title ?? "BCD", year: civil.year, month: civil.month, day: civil.day,
                                               hour: civil.hour, minute: civil.minute, second: civil.second)
        guard let folder else { say("The picture could not be saved."); return }
        let wantsPhotos = toPhotos
        let size = image.size, pixels = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Encoding and writing are not the main thread's work.
        DispatchQueue.global(qos: .userInitiated).async {
            var data = image.jpegData(compressionQuality: BCDScreenshotRules.jpegQuality)
            if let first = data, first.count > BCDScreenshotRules.keptMaxBytes { data = image.jpegData(compressionQuality: 0.6) }
            let url = folder.appendingPathComponent(name)
            var saved = false
            if let data {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    saved = true
                } catch {
                    DispatchQueue.main.async { LogStore.shared.log("[screenshot] could not write \(name): \(error.localizedDescription)", level: .error) }
                }
            }
            let bytes = data?.count ?? 0
            DispatchQueue.main.async {
                guard saved else { MainActor.assumeIsolated { say("The picture could not be saved.") }; return }
                LogStore.shared.log("[screenshot] saved \(name) \(Int(pixels.width))x\(Int(pixels.height)) (view \(Int(size.width))x\(Int(size.height))) "
                                    + "\(bytes >> 10) KB photos=\(wantsPhotos ? "asked" : "off") black=\(black ? 1 : 0)")
                MainActor.assumeIsolated {
                    if black {
                        say("The picture came out black, so it may show nothing. It is in Files › BCD › Screenshots.")
                    } else if wantsPhotos {
                        addToPhotos(url)
                    } else {
                        say("Screenshot saved in Files › BCD › Screenshots.")
                    }
                }
            }
        }
    }

    /// A picture that is all (nearly) black: the surface had nothing drawn into it that the compositor would give.
    static func isBlack(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = 24, h = 14
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return false }
        var sum = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) }
        return sum / (w * h * 3) < 3
    }

    /// Photos, add-only. The first time the system asks the player; a refusal is said once and the picture stays in Files.
    private static func addToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    LogStore.shared.log("[screenshot] Photos refused (status \(status.rawValue)); the picture stays in Files")
                    MainActor.assumeIsolated { say("Saved in Files › BCD › Screenshots. Photos is off for BCD in Settings.") }
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }, completionHandler: { ok, error in
                DispatchQueue.main.async {
                    LogStore.shared.log(ok ? "[screenshot] added to Photos" : "[screenshot] Photos did not take it: \(error?.localizedDescription ?? "unknown")")
                    MainActor.assumeIsolated { say(ok ? "Screenshot saved to Photos and Files › BCD › Screenshots." : "Saved in Files › BCD › Screenshots. Photos did not take it.") }
                }
            })
        }
    }

    /// The line over the game for a few seconds (the session line, which the layer already shows).
    private static func say(_ text: String) {
        let model = LibraryModel.shared
        guard model.current != nil else { return }
        model.sessionMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if model.sessionMessage == text { model.sessionMessage = "" }
        }
    }

    // MARK: Send Log

    /// The newest picture that belongs to `log` (taken while it was being written, give or take a minute), or nil.
    static func candidate(for log: URL) -> URL? {
        guard let folder else { return nil }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let end = LogUpload.modified(log)
        let start = BCDScreenshotRules.start(ofLogNamed: log.lastPathComponent)
        let shots = names.filter { $0.pathExtension.lowercased() == "jpg" }.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return BCDScreenshotRules.belongs(shot: date, logStart: start, logEnd: end) ? (url, date) : nil
        }
        return shots.max { $0.1 < $1.1 }?.0
    }
}
