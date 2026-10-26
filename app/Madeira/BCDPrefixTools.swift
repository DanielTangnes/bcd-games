// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI
import UniformTypeIdentifiers

// Settings › Storage › Windows prefix (round 604): copies of the prefix's own part, an export to Files, an import, a fresh registry and
// Wine's system files put back. The words and rows are here and know nothing of the engine: the live backend
// (BCDGameSetup/BCDPrefixToolsLive.swift) does the work (BCDGameSetup/BCDPrefixKit.swift says what the "own part" is), and the preview
// app can show the group from a sample backend.
//
// What every row says it does is what it does: nothing here touches a game, and nothing runs while a game does. Every action that
// replaces something asks first, and makes a copy of what it replaces first ("Before ...") that stays in Files › BCD › Prefix Copies.

struct BCDPrefixCopyItem: Identifiable, Equatable {
    var id: String
    var made: Date?
}

@MainActor protocol BCDPrefixBackend: ObservableObject {
    var busy: Bool { get }
    var message: String? { get }
    var copies: [BCDPrefixCopyItem] { get }
    /// Why the tools cannot run now (a game is running or starting), or nil.
    var blocked: String? { get }
    func refresh()
    func makeCopy()
    func putBack(_ id: String)
    func deleteCopy(_ id: String)
    func exportKit()
    /// What the zip holds ("made on ..., 1 user, 312 files"), or why it is not one BCD's export made.
    func describeImport(_ url: URL) -> String
    func importKit(from url: URL)
    func reconfigure()
    func reinstallSystemFiles()
}

enum BCDPrefixWords {
    static let groupFooter = "A copy keeps the part of the prefix that is yours: the registry, the users' folders and C:\\ProgramData, without caches. Games and Wine's own files are not in it. Everything here waits while a game runs, and each change that replaces something first makes a \"Before\" copy that stays in Files › BCD › Prefix Copies."

    static func copyQuestion(_ item: BCDPrefixCopyItem) -> (title: String, message: String) {
        ("Put back the copy \"\(item.id)\"?",
         "The registry and the users' files in the copy replace the files with the same names in the prefix. Files the copy does not hold stay. BCD makes a \"Before put back\" copy of what is there now first. Games are not touched.")
    }

    static let reconfigureQuestion = (
        title: "Start from a fresh registry?",
        message: "The three registry files go back to what BCD ships: Wine's defaults, without what installers and games added (their settings in the registry, installed runtimes' entries). Users' folders, saves, games and Wine's files stay. BCD makes a \"Before reconfigure\" copy first, and refuses when this prefix's Windows user is not the one the fresh registry names.")

    static let reinstallQuestion = (
        title: "Put Wine's system files back?",
        message: "Files of C:\\windows that BCD ships and that are missing or empty in the prefix come back (fonts, inf files, win.ini and the like). Nothing that exists is replaced, and the registry stays. Wine's DLLs are linked again at every start anyway.")

    static func importQuestion(_ summary: String) -> (title: String, message: String) {
        ("Import this prefix export?",
         summary + "\n\nIts registry files and users' files replace the files with the same names in the prefix; other files stay. BCD makes a \"Before import\" copy first. Games are not part of an export.")
    }
}

struct BCDPrefixToolsGroup<Backend: BCDPrefixBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "Windows prefix", footer: BCDPrefixWords.groupFooter) {
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-copy"), title: backend.busy ? "Working…" : "Make a copy now",
                                     note: backend.blocked ?? backend.message, symbol: "doc.on.doc", enabled: enabled) { backend.makeCopy() }
                ForEach(backend.copies) { item in copyRow(item) }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-export"), title: "Export to Files",
                                     note: "A zip of the same part, for another device, in Files › BCD › Prefix Exports.", symbol: "square.and.arrow.up", enabled: enabled) {
                    backend.exportKit()
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-import"), title: "Import an export",
                                     note: "Choose a zip BCD's export made.", symbol: "square.and.arrow.down", enabled: enabled) { importing = true }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-reconfigure"), title: "Start from a fresh registry",
                                     note: "At the next start the registry is the one BCD ships.", symbol: "arrow.counterclockwise", enabled: enabled) {
                    let q = BCDPrefixWords.reconfigureQuestion
                    model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [.init(title: "Start fresh", destructive: true) { backend.reconfigure() }]))
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-system"), title: "Put Wine's system files back",
                                     note: "Brings back what is missing or empty in C:\\windows.", symbol: "wrench.and.screwdriver", enabled: enabled) {
                    let q = BCDPrefixWords.reinstallQuestion
                    model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [.init(title: "Put back") { backend.reinstallSystemFiles() }]))
                }
            }
        }
        .onAppear { backend.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            let summary = backend.describeImport(url)
            let q = BCDPrefixWords.importQuestion(summary)
            model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [.init(title: "Import", destructive: true) { backend.importKit(from: url) }]))
        }
    }

    private var enabled: Bool { !backend.busy && backend.blocked == nil }

    private func copyRow(_ item: BCDPrefixCopyItem) -> some View {
        BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-copy." + item.id), title: item.id,
                             note: "A copy of the prefix's own part. Choose it to put it back or delete it.", detail: item.made.map { BCDFormat.dateTime($0) },
                             symbol: "clock.arrow.circlepath", enabled: enabled) {
            let q = BCDPrefixWords.copyQuestion(item)
            model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [
                .init(title: "Put this copy back", destructive: true) { backend.putBack(item.id) },
                .init(title: "Delete this copy", destructive: true) { backend.deleteCopy(item.id) },
            ]))
        }
    }
}
