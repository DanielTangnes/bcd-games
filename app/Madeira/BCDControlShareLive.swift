// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
import UIKit
import UniformTypeIdentifiers

// Shareable control layouts on the engine (the file's rules: BCDControlShareCore.swift). Settings › Controls has two rows:
//  - "Share <layout>": the player's own layout, encoded by the app's own encoder, written as a small JSON file in the temporary folder and
//    handed to the system's share sheet (Files, Messages, AirDrop...). The temporary file is removed when the sheet is done.
//  - "Add a layout from a file": the system's document picker (a copy of the file is read, never the original), the size is checked before the
//    bytes are read, BCDControlShare.parse checks the envelope and each control, the app's decoder is the second gate, the name is made
//    unique, and the layout is added to the list (ControlPresetsModel.importLayout). It never replaces a layout and never puts controls on screen.
// Nothing here goes to the network. Left out of the preview build (tools/ui-preview.py, ENGINE_BOUND).

@MainActor enum BCDControlShareLive {
    /// Keeps the picker's delegate alive while the picker is up.
    private static var pending: PickerDelegate?

    static func share(layoutID: String) {
        let presets = ControlPresetsModel.shared
        guard let preset = presets.store.preset(layoutID), !ControlPresetStore.isBuiltIn(preset.id) else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let data: Data
        do {
            let controls = try JSONEncoder().encode(preset.controls)
            data = try BCDControlShare.export(name: preset.name, game: nil, build: build, controlsJSON: controls)
        } catch {
            return tell("The layout could not be saved as a file.", detail: (error as? BCDControlShare.Problem)?.words ?? error.localizedDescription)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(BCDControlShare.fileName(for: preset.name))
        do { try data.write(to: url, options: .atomic) } catch { return tell("The layout could not be saved as a file.", detail: error.localizedDescription) }
        LogStore.shared.log("[controls-share] \(preset.controls.count) controls shared as a \(data.count)-byte file")
        guard let top = topController() else { try? FileManager.default.removeItem(at: url); return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(sheet, animated: true)
    }

    static func importFile() {
        guard let top = topController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = PickerDelegate()
        picker.delegate = delegate
        pending = delegate
        top.present(picker, animated: true)
    }

    fileprivate static func picked(_ url: URL) {
        pending = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= BCDControlShare.maxBytes else { return tell(BCDControlShare.Problem.tooBig.words, detail: nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            try? FileManager.default.removeItem(at: url)   // the picker's copy
            DispatchQueue.main.async { MainActor.assumeIsolated { finishImport(data) } }
        }
    }

    private static func finishImport(_ data: Data?) {
        guard let data else { return tell("That file could not be read.", detail: nil) }
        switch BCDControlShare.parse(data) {
        case .failure(let problem):
            LogStore.shared.log("[controls-share] a file was refused: \(problem.words)")
            tell("The layout was not added.", detail: problem.words)
        case .success(let parsed):
            let controls: [TouchControl]
            do { controls = try JSONDecoder().decode([TouchControl].self, from: parsed.controlsJSON) } catch {
                LogStore.shared.log("[controls-share] a file was refused: the decoder said \(error.localizedDescription)")
                return tell("The layout was not added.", detail: "It uses something this BCD does not know. A newer BCD may have made it.")
            }
            let presets = ControlPresetsModel.shared
            let name = BCDControlShare.importName(parsed.name, taken: presets.store.all.map(\.name))
            guard presets.importLayout(name: name, controls: controls) != nil else {
                return tell("The layout was not added.", detail: "BCD could not save its layout list.")
            }
            LogStore.shared.log("[controls-share] added a layout of \(controls.count) controls")
            tell("Layout added", detail: BCDControlShare.added(parsed, as: name))
        }
    }

    // MARK: Alerts and screens

    private static func tell(_ title: String, detail: String?) {
        guard let top = topController() else { return }
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top.present(alert, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { BCDControlShareLive.picked(url) } }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async { MainActor.assumeIsolated { BCDControlShareLive.pending = nil } }
        }
    }
}
