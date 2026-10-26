// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Settings › Storage › Windows prefix, engine side (BCDPrefixTools.swift has the words and rows, BCDPrefixKit.swift the file work).
// Everything runs on a background queue and only while no game runs (the wineserver keeps the registry in memory while one does);
// every action that replaces something makes a "Before ..." copy first and stops when it cannot. The log carries counts, never paths.

@MainActor final class BCDPrefixToolsLive: BCDPrefixBackend {
    static let shared = BCDPrefixToolsLive()

    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var copies: [BCDPrefixCopyItem] = []

    private nonisolated static var prefix: URL { BCDGameSetup.prefix }
    private nonisolated static var copiesFolder: URL { LibraryModel.documents.appendingPathComponent("Prefix Copies", isDirectory: true) }
    private nonisolated static var exportsFolder: URL { LibraryModel.documents.appendingPathComponent("Prefix Exports", isDirectory: true) }

    var blocked: String? {
        let library = LibraryModel.shared
        let running = wine_process_is_running() != 0 || wineserver_is_running() != 0 || library.current != nil || library.launching
        return running ? "Quit the game first: the registry is in use while a game runs." : nil
    }

    func refresh() {
        let folder = Self.copiesFolder
        DispatchQueue.global(qos: .utility).async {
            let list = BCDPrefixKit.copies(in: folder).map { BCDPrefixCopyItem(id: $0.name, made: $0.made) }
            DispatchQueue.main.async { [weak self] in self?.copies = list }
        }
    }

    // MARK: Work

    /// Runs `work` off the main thread; its result line (or the error's words) becomes the message.
    private func run(_ working: String, _ work: @escaping @Sendable () throws -> String) {
        guard !busy, blocked == nil else { return }
        busy = true
        message = working
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Swift.Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                busy = false
                switch result {
                case .success(let text):
                    message = text
                    LogStore.shared.log("[prefix] " + text)
                case .failure(let error):
                    message = error.localizedDescription
                    LogStore.shared.log("[prefix] failed: " + error.localizedDescription)
                }
                refresh()
            }
        }
    }

    /// The copy of what is there now that an action makes first.
    private nonisolated static func before(_ label: String) throws {
        _ = try BCDPrefixKit.makeCopy(prefix: prefix, into: copiesFolder, name: BCDPrefixKit.stamp(Date()) + " " + label)
    }

    private nonisolated static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    func makeCopy() {
        run("Making a copy…") {
            let made = try BCDPrefixKit.makeCopy(prefix: Self.prefix, into: Self.copiesFolder, name: BCDPrefixKit.stamp(Date()))
            return "Copy made: \(Self.plural(made.files, "file")), \(BCDFormat.bytes(made.bytes)), in Files › BCD › Prefix Copies › \(made.copy.name)."
        }
    }

    func putBack(_ id: String) {
        guard let url = BCDPrefixKit.copies(in: Self.copiesFolder).first(where: { $0.name == id })?.url else { message = "That copy is not there any more."; return }
        run("Putting the copy back…") {
            try Self.before("Before put back")
            let n = try BCDPrefixKit.putBack(url, prefix: Self.prefix)
            return "Put back \(Self.plural(n, "file")) from the copy. The next start uses them."
        }
    }

    func deleteCopy(_ id: String) {
        guard let url = BCDPrefixKit.copies(in: Self.copiesFolder).first(where: { $0.name == id })?.url else { message = "That copy is not there any more."; return }
        run("Deleting the copy…") {
            try FileManager.default.removeItem(at: url)
            return "Copy deleted."
        }
    }

    func exportKit() {
        run("Packing the prefix's own part…") {
            let url = Self.exportsFolder.appendingPathComponent(BCDPrefixKit.stamp(Date()) + " Prefix.zip")
            let made = try BCDPrefixKit.exportZip(prefix: Self.prefix, to: url)
            return "Exported \(Self.plural(made.files, "file")) (\(BCDFormat.bytes(made.bytes))) to Files › BCD › Prefix Exports › \(url.lastPathComponent)."
                + (made.links > 0 ? " \(Self.plural(made.links, "save folder")) moved out of the prefix stay in Game Saves." : "")
        }
    }

    func describeImport(_ url: URL) -> String {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        guard let info = try? BCDPrefixKit.inspect(zip: url) else { return "This zip was not made by BCD's prefix export, so BCD cannot import it." }
        return "Made \(info.made.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")); \(Self.plural(info.files, "file")), "
            + "Windows user\(info.users.count == 1 ? "" : "s") \(info.users.isEmpty ? "none" : info.users.joined(separator: ", "))."
    }

    func importKit(from url: URL) {
        // The picked file is read in place only while access is open; a copy in the app's own temporary folder is what the work reads.
        let opened = url.startAccessingSecurityScopedResource()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-import-\(UUID().uuidString).zip")
        let copied = (try? FileManager.default.copyItem(at: url, to: local)) != nil
        if opened { url.stopAccessingSecurityScopedResource() }
        guard copied else { message = "The zip could not be read."; return }
        run("Importing…") {
            defer { try? FileManager.default.removeItem(at: local) }
            guard (try? BCDPrefixKit.inspect(zip: local)) != nil else { throw BCDPrefixKit.Failure(text: "This zip was not made by BCD's prefix export.") }
            try Self.before("Before import")
            let result = try BCDPrefixKit.importZip(local, prefix: Self.prefix)
            return "Imported \(Self.plural(result.written, "file"))" + (result.refused > 0 ? "; \(result.refused) entries outside the prefix's own part were left out" : "") + ". The next start uses them."
        }
    }

    // MARK: Reconfigure, system files

    /// The template extracted to a scratch folder (madeira_extract_prefix_tgz); the caller removes it.
    private nonisolated static func extractTemplate() throws -> URL {
        guard let archive = Bundle.main.path(forResource: "prefix-template", ofType: "tar.gz") else { throw BCDPrefixKit.Failure(text: "BCD's prefix template is not in the app.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bcd-template-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard madeira_extract_prefix_tgz(archive, folder.path) == 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw BCDPrefixKit.Failure(text: "BCD's prefix template could not be unpacked.")
        }
        return folder
    }

    func reconfigure() {
        run("Making the fresh registry…") {
            let template = try Self.extractTemplate()
            defer { try? FileManager.default.removeItem(at: template) }
            let user = BCDFixPaths.users(drive: template.appendingPathComponent("drive_c")).first ?? ""
            guard !user.isEmpty else { throw BCDPrefixKit.Failure(text: "BCD's template has no Windows user.") }
            // Refused, with the reason, before any copy is made, when the prefix's Windows user is another one.
            try BCDPrefixKit.requireUser(prefix: Self.prefix, templateUser: user)
            try Self.before("Before reconfigure")
            try BCDPrefixKit.reconfigure(prefix: Self.prefix, template: template, templateUser: user)
            return "The registry is the one BCD ships. The next start uses it; the copy before it is in Prefix Copies."
        }
    }

    func reinstallSystemFiles() {
        run("Looking at Wine's system files…") {
            let template = try Self.extractTemplate()
            defer { try? FileManager.default.removeItem(at: template) }
            let n = try BCDPrefixKit.reinstallSystemFiles(prefix: Self.prefix, template: template)
            return n == 0 ? "Nothing was missing." : "Put back \(Self.plural(n, "file")) of Windows' own folder."
        }
    }
}
