// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The HUD's rows in the in-game menu (Display › Performance HUD) and the Custom HUD's page, as plain values: BCDHUDMenu.sections and
// .page make the rows, and .toggle, .choose, .slide and .act turn a tap into a new setup. The live menu (BCDSessionLive.swift) and the
// preview app both use them, so a photograph of the preview is the menu the app shows. Nothing here touches the engine.

enum BCDHUDMenu {
    /// A tap's result: the setup afterwards, and whether the player asked to move the HUD by hand (the menu then closes and the HUD
    /// waits for a drag).
    struct Outcome: Equatable {
        var setup: BCDHUDSetup
        var moving = false
    }

    static let layoutRow = "hud.layout"
    static let customPage = "hud.custom"

    /// Whether a row of the menu is one of the HUD's.
    static func owns(_ row: String) -> Bool { row.hasPrefix("hud.") || row.hasPrefix("hudi.") }

    // MARK: The Display tab

    static func sections(_ setup: BCDHUDSetup, screen: BCDHUDScreenClass) -> [BCDMenuSection] {
        var rows = [BCDMenuRow(id: layoutRow, title: "Performance HUD", detail: setup.layout.summary,
                               kind: .choice(BCDHUDLayout.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: setup.layout.rawValue))]
        if setup.layout.shown {
            let place = setup.place(screen)
            var places = [BCDChoice(id: "auto", title: "Auto")] + BCDHUDSlot.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }
            places.append(BCDChoice(id: "move", title: "By hand"))
            rows.append(BCDMenuRow(id: "hud.place", title: "Position", detail: placeDetail(place), kind: .choice(places, selected: placeChoice(place))))
            if setup.layout == .custom {
                let count = setup.custom.items.count
                rows.append(BCDMenuRow(id: "hud.custom", title: "Custom HUD", detail: "Pick the readings, their shape, size and clearness.",
                                       symbol: "slider.horizontal.3",
                                       kind: .page(customPage, value: count == 1 ? "1 reading" : "\(count) readings")))
            }
        }
        return [BCDMenuSection(id: "hud", title: "Performance HUD", rows: rows)]
    }

    static func placeChoice(_ place: BCDHUDPlace) -> String {
        switch place {
        case .auto: return "auto"
        case .slot(let slot): return slot.rawValue
        case .dragged: return "move"
        }
    }

    static func placeDetail(_ place: BCDHUDPlace) -> String {
        switch place {
        case .auto: return "BCD finds a spot clear of the touch controls and, if the picture leaves a bar, in the bar."
        case .slot: return "Fixed in that corner or at that edge."
        case .dragged: return "Where you put it. Choose By hand to move it again."
        }
    }

    // MARK: The Custom page

    static func page(_ id: String, _ setup: BCDHUDSetup) -> BCDMenuPage? {
        guard id == customPage else { return nil }
        let custom = setup.custom
        var sections: [BCDMenuSection] = []
        sections.append(BCDMenuSection(id: "hud.start", title: "Start from", rows: [
            BCDMenuRow(id: "hud.copy", title: "Copy a finished layout into the list",
                       detail: "Replaces the readings below with that layout's.",
                       kind: .choice(BCDHUDLayout.presets.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: "")),
        ]))
        let on = Set(custom.items)
        for group in BCDHUDItem.Group.allCases {
            let rows = BCDHUDItem.allCases.filter { $0.group == group }.map { item in
                BCDMenuRow(id: "hudi." + item.rawValue, title: item.title, detail: item.note, kind: .toggle(on.contains(item)))
            }
            sections.append(BCDMenuSection(id: "hud.group." + group.rawValue, title: group.rawValue, rows: rows))
        }
        var look = [
            BCDMenuRow(id: "hud.shape", title: "Shape", detail: shapeDetail(custom.shape),
                       kind: .choice(BCDHUDCustom.Shape.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: custom.shape.rawValue)),
            BCDMenuRow(id: "hud.size", title: "Size", detail: "Text 10, 12 or 14 points.",
                       kind: .choice(BCDHUDCustom.Size.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: custom.size.rawValue)),
            BCDMenuRow(id: "hud.textopacity", title: "Text clearness",
                       kind: .slider(custom.textOpacity, 0.4...1, step: 0.05, text: percent(custom.textOpacity))),
            BCDMenuRow(id: "hud.bgopacity", title: "Background",
                       detail: "A background under 25% gets a thin dark edge round the letters.",
                       kind: .slider(custom.backgroundOpacity, 0...1, step: 0.05, text: percent(custom.backgroundOpacity))),
        ]
        if on.contains(.frameGraph) {
            look.append(BCDMenuRow(id: "hud.graph", title: "Graph length",
                                   kind: .choice([15, 30, 60].map { BCDChoice(id: String($0), title: "\($0) s") }, selected: String(custom.graphSeconds))))
        }
        look.append(BCDMenuRow(id: "hud.dim", title: "Fade when calm", detail: "Half clear after 6 seconds without a change, and back at once when something changes.",
                               kind: .toggle(custom.dimWhenCalm)))
        sections.append(BCDMenuSection(id: "hud.look", title: "Look", rows: look))
        sections.append(BCDMenuSection(id: "hud.reset", rows: [
            BCDMenuRow(id: "hud.reset", title: "Back to the starting list", symbol: "arrow.counterclockwise", kind: .action(destructive: true),
                       confirm: BCDConfirm(title: "Back to the starting list?", message: "The readings, shape, size and clearness go back to how a new Custom HUD starts.",
                                           answers: [.init(id: "reset", title: "Back to the starting list", destructive: true)])),
        ]))
        return BCDMenuPage(id: customPage, title: "Custom HUD", sections: sections)
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private static func shapeDetail(_ shape: BCDHUDCustom.Shape) -> String {
        switch shape {
        case .strip: return "Readings side by side, in lines that wrap."
        case .list: return "One reading to a line."
        case .table: return "Two columns."
        }
    }

    // MARK: A tap

    static func toggle(_ row: String, _ on: Bool, _ setup: BCDHUDSetup) -> Outcome {
        var setup = setup
        if row == "hud.dim" {
            setup.custom.dimWhenCalm = on
            setup.custom.touched = true
        } else if row.hasPrefix("hudi."), let item = BCDHUDItem(rawValue: String(row.dropFirst(5))) {
            var items = setup.custom.items.filter { $0 != item }
            if on { items.append(item) }
            // The editor lists them in the order of the groups, whatever order they were switched on in.
            setup.custom.items = BCDHUDCustom.canonical(items)
            setup.custom.touched = true
        }
        return Outcome(setup: setup)
    }

    static func choose(_ row: String, _ value: String, _ setup: BCDHUDSetup, screen: BCDHUDScreenClass) -> Outcome {
        var setup = setup
        var moving = false
        switch row {
        case layoutRow:
            guard let layout = BCDHUDLayout(rawValue: value) else { break }
            let before = setup.layout
            if layout == .custom, !setup.custom.touched, BCDHUDLayout.presets.contains(before) {
                // Custom starts as a copy of the layout the player was on, so the editor never opens on an empty list.
                setup.custom = BCDHUDCustom.startingFrom(before)
            }
            setup.layout = layout
        case "hud.place":
            switch value {
            case "auto": setup.set(.auto, for: screen)
            case "move": moving = true
            default: if let slot = BCDHUDSlot(rawValue: value) { setup.set(.slot(slot), for: screen) }
            }
        case "hud.shape":
            if let shape = BCDHUDCustom.Shape(rawValue: value) { setup.custom.shape = shape; setup.custom.touched = true }
        case "hud.size":
            if let size = BCDHUDCustom.Size(rawValue: value) { setup.custom.size = size; setup.custom.touched = true }
        case "hud.graph":
            if let seconds = Int(value), [15, 30, 60].contains(seconds) { setup.custom.graphSeconds = seconds; setup.custom.touched = true }
        case "hud.copy":
            if let layout = BCDHUDLayout(rawValue: value), BCDHUDLayout.presets.contains(layout) {
                let keep = setup.custom
                var copy = BCDHUDCustom.startingFrom(layout)
                copy.textOpacity = keep.textOpacity
                copy.backgroundOpacity = keep.backgroundOpacity
                copy.touched = true
                setup.custom = copy
            }
        default:
            break
        }
        return Outcome(setup: setup, moving: moving)
    }

    static func slide(_ row: String, _ value: Double, _ setup: BCDHUDSetup) -> Outcome {
        var setup = setup
        switch row {
        case "hud.textopacity":
            setup.custom.textOpacity = BCDHUDCustom.clamp((value * 20).rounded() / 20, 0.4, 1)
            setup.custom.touched = true
        case "hud.bgopacity":
            setup.custom.backgroundOpacity = BCDHUDCustom.clamp((value * 20).rounded() / 20, 0, 1)
            setup.custom.touched = true
        default:
            break
        }
        return Outcome(setup: setup)
    }

    /// The answer to a question (the reset's): a Custom HUD back to how a new one starts.
    static func answer(_ row: String, _ answer: String, _ setup: BCDHUDSetup) -> Outcome {
        guard row == "hud.reset", answer == "reset" else { return Outcome(setup: setup) }
        var setup = setup
        setup.custom = .default
        return Outcome(setup: setup)
    }
}
