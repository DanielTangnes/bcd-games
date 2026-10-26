// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// Game setup (round 604, A12): a game's saves outside the Windows prefix. A save folder BCD found for a game (the roots of the save
// backups, BCDSaveBackups/) can live in Files › BCD › Game Saves instead of inside Documents/wine: BCD moves the folder there and
// leaves a link in its place, so the game opens the same path as before and the files are where the Files app shows them, outside the
// prefix. Resetting the prefix, removing it, or exporting only its system part leaves them alone; the next start of the game makes the
// link again if the prefix lost it.
//
// Foundation only, tests/host/check-game-setup.py runs it on a scratch prefix. What it never does: delete a file (a folder is
// moved, with the rename the file system makes, and moved back the same way), move a folder while a session runs (the caller checks),
// touch a folder that is not a folder under a Windows user's Documents, Saved Games or AppData, replace a place that holds files
// already (a restore finds the way back blocked and says so), or write a link with an absolute path (the container's path changes
// when the app is reinstalled; the link is relative to Documents, so it keeps working).

enum BCDSaveRedirect {
    /// One redirected folder.
    struct Record: Codable, Equatable {
        /// The game's own key (its program's Windows path, lower case), which survives a rename.
        var game: String
        /// The name the game's folder in Game Saves has.
        var title: String?
        /// The place in the prefix, relative to drive_c with "/".
        var root: String
        /// The folder in Game Saves, relative to Game Saves with "/".
        var place: String
    }

    enum State: Equatable {
        case inPrefix
        /// A link to `place` is where the folder was.
        case redirected(place: String)
        /// The record says redirected, the folder is in Game Saves, and the prefix has no link (it was reset): the next start makes it.
        case needsLink(place: String)
        /// There is nothing in the prefix at that path.
        case missing
    }

    struct Failure: LocalizedError {
        var text: String
        var errorDescription: String? { text }
    }

    static let stateName = ".bcd-redirects.json"

    /// Documents/Game Saves, where the Files app shows it.
    static func folder(documents: URL) -> URL { documents.appendingPathComponent("Game Saves", isDirectory: true) }

    // MARK: Records

    static func records(in folder: URL) -> [Record] {
        (try? JSONDecoder().decode([Record].self, from: Data(contentsOf: folder.appendingPathComponent(stateName)))) ?? []
    }

    private static func save(_ list: [Record], in folder: URL) {
        let url = folder.appendingPathComponent(stateName)
        if list.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Which folders may move

    /// A folder root below a Windows user's Documents, Saved Games or AppData (Roaming, Local, LocalLow), at least one folder
    /// down ("users/u/Documents/My Games/Foo", "users/u/AppData/Roaming/Vendor").
    static func isEligible(_ root: GameSaveRoot) -> Bool {
        guard !root.isFile, let parts = GameSaveRules.parts(root.path), parts.count >= 4, parts[0].lowercased() == "users",
              parts[1].caseInsensitiveCompare("Public") != .orderedSame else { return false }
        switch parts[2].lowercased() {
        case "documents", "saved games": return parts.count >= 4
        case "appdata":
            guard parts.count >= 5 else { return false }
            return ["roaming", "local", "locallow"].contains(parts[3].lowercased())
        default: return false
        }
    }

    /// The name a root gets in Game Saves: how the player reads it, without the Windows user ("Documents - My Games - Foo").
    static func placeName(_ root: GameSaveRoot) -> String {
        GameSaveRules.display(root).replacingOccurrences(of: " › ", with: " - ")
    }

    // MARK: Looking

    private static func disk(_ path: String, drive: URL) -> URL {
        var url = drive
        let parts = GameSaveRules.parts(path) ?? []
        for (index, part) in parts.enumerated() {
            let exact = url.appendingPathComponent(part, isDirectory: index < parts.count - 1)
            if (try? FileManager.default.attributesOfItem(atPath: exact.path)) != nil { url = exact; continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            url = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }).map { url.appendingPathComponent($0, isDirectory: index < parts.count - 1) } ?? exact
        }
        return url
    }

    static func state(of root: GameSaveRoot, game: String, drive: URL, folder: URL) -> State {
        let link = disk(root.path, drive: drive)
        let record = records(in: folder).first { $0.game == game && $0.root.lowercased() == root.path.lowercased() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: link.path)
        if (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink, let record { return .redirected(place: record.place) }
        if attributes == nil {
            if let record, FileManager.default.fileExists(atPath: folder.appendingPathComponent(record.place).path) { return .needsLink(place: record.place) }
            return .missing
        }
        return .inPrefix
    }

    // MARK: Moving

    /// The relative path a link at `link` uses to reach `target` (both real places in the same container).
    static func relativePath(from link: URL, to target: URL) -> String {
        let from = link.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let to = target.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + Array(to[common...])).joined(separator: "/")
    }

    private static func count(_ url: URL) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        while let item = walk?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
            if files > 200_000 { break }
        }
        return (files, bytes)
    }

    /// What a move would touch, for the question.
    static func size(of root: GameSaveRoot, drive: URL) -> (files: Int, bytes: Int64) { count(disk(root.path, drive: drive)) }

    /// Moves the root's folder into Game Saves and leaves a relative link. Returns the files and bytes that moved.
    @discardableResult
    static func redirect(_ root: GameSaveRoot, game: String, title: String? = nil, drive: URL, folder: URL) throws -> (files: Int, bytes: Int64, place: String) {
        let fm = FileManager.default
        guard isEligible(root) else { throw Failure(text: "BCD moves only a folder under a user's Documents, Saved Games or AppData.") }
        let source = disk(root.path, drive: drive)
        guard let attributes = try? fm.attributesOfItem(atPath: source.path) else { throw Failure(text: "That folder is not in the prefix yet.") }
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else { throw Failure(text: "That place is already a link or not a folder.") }
        var list = records(in: folder)
        guard !list.contains(where: { $0.game == game && $0.root.lowercased() == root.path.lowercased() }) else { throw Failure(text: "That folder is already outside the prefix.") }

        // The place: Game Saves/<game>/<name>, a number after the name when the name is taken.
        let gameFolderName = GameSaveRules.safeFolderName(title ?? game)
        let gameFolder = folder.appendingPathComponent(gameFolderName, isDirectory: true)
        let name = GameSaveRules.safeFolderName(placeName(root))
        var destination = gameFolder.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = gameFolder.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        let measured = count(source)
        try fm.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
        let relative = relativePath(from: source, to: destination)
        do {
            try fm.createSymbolicLink(atPath: source.path, withDestinationPath: relative)
        } catch {
            try? fm.moveItem(at: destination, to: source)   // the way back: nothing is lost
            throw Failure(text: "The link could not be made: \(error.localizedDescription). The folder stays where it was.")
        }
        let place = gameFolderName + "/" + destination.lastPathComponent
        list.append(Record(game: game, title: title, root: root.path, place: place))
        save(list, in: folder)
        return (measured.files, measured.bytes, place)
    }

    /// Puts the folder back into the prefix: the link goes, the folder moves back to its place. Refuses when the prefix holds a
    /// folder of its own at that path (the game made a new one): neither is touched.
    static func restore(_ root: GameSaveRoot, game: String, drive: URL, folder: URL) throws {
        let fm = FileManager.default
        var list = records(in: folder)
        guard let index = list.firstIndex(where: { $0.game == game && $0.root.lowercased() == root.path.lowercased() }) else {
            throw Failure(text: "BCD has no record of that folder being moved.")
        }
        let record = list[index]
        let held = folder.appendingPathComponent(record.place, isDirectory: true)
        guard fm.fileExists(atPath: held.path) else { throw Failure(text: "The folder is not in Game Saves any more, so there is nothing to move back.") }
        let target = disk(root.path, drive: drive)
        let attributes = try? fm.attributesOfItem(atPath: target.path)
        if let attributes {
            guard (attributes[.type] as? FileAttributeType) == .typeSymbolicLink else {
                throw Failure(text: "The game has made a folder of its own there. Neither is touched: move or remove one of them in Files first.")
            }
            try fm.removeItem(at: target)   // the link only
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.moveItem(at: held, to: target)
        list.remove(at: index)
        save(list, in: folder)
    }

    /// For a start of the game: makes again the links the prefix lost (it was reset). Returns log lines (counts, no paths).
    static func repair(game: String, drive: URL, folder: URL) -> [String] {
        let fm = FileManager.default
        var made = 0, blocked = 0
        for record in records(in: folder) where record.game == game {
            let held = folder.appendingPathComponent(record.place, isDirectory: true)
            guard fm.fileExists(atPath: held.path) else { continue }
            let link = disk(record.root, drive: drive)
            if (try? fm.attributesOfItem(atPath: link.path)) != nil { continue }   // a link already, or a folder of the game's own
            guard (try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                  (try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: relativePath(from: link, to: held))) != nil else { blocked += 1; continue }
            made += 1
        }
        var lines: [String] = []
        if made > 0 { lines.append("[saves] \(game): \(made) save folder\(made == 1 ? "" : "s") outside the prefix linked again") }
        if blocked > 0 { lines.append("[saves] \(game): \(blocked) link\(blocked == 1 ? "" : "s") could not be made") }
        return lines
    }
}
