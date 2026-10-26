// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// The performance HUD's views (design: BCDHUDCore.swift). The live side (BCDHUDLive.swift) puts a plan into the feed twice or four times
// a second and only when it changed; these views draw the plan and place it. They name no engine type, so the preview app draws exactly
// what the app draws.
//
// Never in the game's way: the HUD takes no touch except while the player moves it (the layer's window passes every other touch to
// the game), it sits where nothing of the game's controls is, and it is small. Nothing animates on its own and nothing is blurred.

/// What the HUD shows now and where it is. The layer reads it; the live side writes it.
@MainActor final class BCDHUDFeed: ObservableObject {
    @Published var plan: BCDHUDPlan?
    /// The layout and the shape of a Custom one: when they change, placement forgets the size it was chosen with.
    @Published var shapeKey = ""
    /// Where the player put it on each kind of screen (BCDHUDSetup.places); a screen without an entry is BCD's own placement.
    @Published var places: [String: BCDHUDPlace] = [:]
    /// Layouts 3 and 4 fade after a few calm seconds.
    @Published var dimmed = false
    /// The player is moving it: it takes touches and shows how to finish.
    @Published var editing = false
    /// The room a plate may use, in points; the layer sets it from the window, the live side plans rows to it.
    var available: CGFloat = 360
    /// The window has room to spare (its short side is 600 points or more): a layout may use a wider plate.
    var roomy = false
    /// Counts what moved under the HUD without the plan changing (the game's picture found a new place after a fold or a resize): the
    /// layer reads the feed, so a new number draws the HUD again.
    @Published var layoutRevision = 0
    /// The rectangles in the window the HUD keeps clear of (the touch controls, the menu button), for a viewport size.
    var avoid: @MainActor (CGSize) -> [CGRect] = { _ in [] }
    /// The picture's rectangle in the window; its letterbox bars are places the HUD can sit without covering the game.
    var picture: @MainActor () -> CGRect = { .zero }
    /// The player dropped it somewhere (the shares of the screen), or asked for the automatic place back.
    var moved: @MainActor (BCDHUDPlace, BCDHUDScreenClass) -> Void = { _, _ in }
    var finishedMoving: @MainActor () -> Void = {}
    /// The room changed (the device turned): plan the rows again.
    var relayout: @MainActor () -> Void = {}

    init(plan: BCDHUDPlan? = nil, places: [String: BCDHUDPlace] = [:], editing: Bool = false) {
        self.plan = plan
        self.shapeKey = plan.map { "\($0.layout.rawValue)\($0.columns)" } ?? ""
        self.places = places
        self.editing = editing
    }
}

/// The HUD on the layer: found a place, moved by hand, or docked in a bar.
struct BCDHUDHost: View {
    @ObservedObject var feed: BCDHUDFeed
    let viewport: CGSize
    let insets: EdgeInsets
    /// Where it takes touches (the window), `.zero` while the player is not moving it.
    let report: (CGRect) -> Void

    @State private var size = CGSize(width: 60, height: 22)
    /// The largest the panel has been with this layout: an automatic place is chosen with it, so a reading that gets a character wider
    /// never moves the HUD.
    @State private var stable = CGSize.zero
    @GestureState private var drag = CGSize.zero
    private var edgeInsets: BCDHUDInsets { BCDHUDInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing) }

    var body: some View {
        if let plan = feed.plan {
            let center = self.center(plan)
            ZStack {
                BCDHUDPanel(plan: plan, editing: feed.editing)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                        size = measured
                        stable = CGSize(width: max(stable.width, measured.width), height: max(stable.height, measured.height))
                    }
                    .opacity(feed.dimmed && !feed.editing ? 0.5 : 1)
                    .animation(.easeOut(duration: 0.4), value: feed.dimmed)
                    .overlay(alignment: controlsBelow(center) ? .bottom : .top) {
                        if feed.editing { controls.offset(y: controlsBelow(center) ? 40 : -40).fixedSize() }
                    }
                    .allowsHitTesting(feed.editing)
                    .gesture(feed.editing ? moveGesture(from: center) : nil)
            }
            .position(x: center.x + drag.width, y: center.y + drag.height)
            .onChange(of: feed.shapeKey) { _, _ in stable = .zero }
            .onChange(of: viewport) { _, _ in stable = .zero }   // a window of another size is another placement
            .onChange(of: available) { _, room in feed.available = room; feed.roomy = BCDHUDPlacement.roomy(viewport); feed.relayout() }
            .onChange(of: reportFrame(center)) { _, frame in report(frame) }
            .onAppear {
                if feed.available != available || feed.roomy != BCDHUDPlacement.roomy(viewport) {
                    feed.available = available
                    feed.roomy = BCDHUDPlacement.roomy(viewport)
                    feed.relayout()
                }
                report(reportFrame(center))
            }
            .onDisappear { report(.zero) }
        }
    }

    // MARK: Where

    /// Everything below comes from the size of the window and its safe area as they are now: no device model, no fixed screen size. The
    /// layer re-reads both whenever the window changes (a rotation, a fold or an unfold, a resized Stage Manager window), so nothing here
    /// is cached across a change except what is reset just below.
    private var screen: BCDHUDScreenClass { BCDHUDScreenClass.of(viewport) }
    private var place: BCDHUDPlace { feed.places[screen.rawValue] ?? .auto }

    /// The room a plate may use on this screen: the safe area less a margin, and no more than 420 points.
    private var available: CGFloat { max(160, min(420, viewport.width - insets.leading - insets.trailing - 24)) }

    /// The panel's center in the layer.
    private func center(_ plan: BCDHUDPlan) -> CGPoint {
        let box = size
        switch place {
        case .dragged(let x, let y):
            return BCDHUDPlacement.center(dragged: x, y: y, size: box, viewport: viewport, insets: edgeInsets)
        case .slot(let slot):
            let origin = BCDHUDPlacement.origin(slot: slot, size: box, viewport: viewport, insets: edgeInsets)
            return CGPoint(x: origin.x + box.width / 2, y: origin.y + box.height / 2)
        case .auto:
            let sized = CGSize(width: max(stable.width, box.width), height: max(stable.height, box.height))
            let spot = BCDHUDPlacement.autoSpot(layout: plan.layout, custom: .default, size: sized, viewport: viewport, insets: edgeInsets,
                                                avoid: feed.avoid(viewport), bars: BCDHUDPlacement.bars(picture: feed.picture(), viewport: viewport))
            let origin: CGPoint
            switch spot {
            case .slot(let slot): origin = BCDHUDPlacement.origin(slot: slot, size: box, viewport: viewport, insets: edgeInsets)
            case .at(let point): origin = point
            }
            return CGPoint(x: origin.x + box.width / 2, y: origin.y + box.height / 2)
        }
    }

    /// Auto and Done go under the panel, or over it when the panel is too near the bottom of the window.
    private func controlsBelow(_ center: CGPoint) -> Bool {
        center.y + size.height / 2 + 56 <= viewport.height - insets.bottom
    }

    /// The window rectangle that takes touches while the player moves it: the panel and the buttons beside it.
    private func reportFrame(_ center: CGPoint) -> CGRect {
        guard feed.editing else { return .zero }
        let width = max(size.width, 150) + 16
        let height = size.height + 16 + 54
        let top = controlsBelow(center) ? center.y - size.height / 2 - 8 : center.y - size.height / 2 - 8 - 54
        return CGRect(x: center.x - width / 2, y: top, width: width, height: height)
    }

    private func moveGesture(from center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($drag) { value, state, transaction in
                transaction.animation = nil
                state = value.translation
            }
            .onEnded { value in
                let end = BCDHUDPlacement.clamp(center: CGPoint(x: center.x + value.translation.width, y: center.y + value.translation.height),
                                                size: size, viewport: viewport, insets: edgeInsets)
                feed.moved(.dragged(x: Double(end.x / max(1, viewport.width)), y: Double(end.y / max(1, viewport.height))), screen)
            }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { feed.moved(.auto, screen) } label: { pill("Auto") }
                .buttonStyle(.plain)
                .accessibilityLabel("Let BCD place it")
            Button { feed.finishedMoving() } label: { pill("Done", prominent: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("Done moving the HUD")
        }
    }

    private func pill(_ title: String, prominent: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(prominent ? Color.white : BCDStyle.lavender)
            .padding(.horizontal, 16).frame(minHeight: 34)
            .background { if prominent { Capsule().fill(BCDStyle.glow) } else { Capsule().fill(BCDSessionStyle.panel.opacity(0.95)) } }
            .overlay(Capsule().strokeBorder(BCDStyle.stroke, lineWidth: prominent ? 0 : 1))
            .contentShape(Capsule())
    }
}

/// A plan, drawn: one dark plate, the rows in 11 to 14 pt rounded type with figures of one width, the graph under them.
struct BCDHUDPanel: View {
    let plan: BCDHUDPlan
    var editing = false

    var body: some View {
        content
            .padding(.horizontal, plan.capsule ? 9 : 9).padding(.vertical, plan.capsule ? 3 : 6)
            .background { plate }
            .overlay { outline }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(plan.spoken)
    }

    @ViewBuilder private var plate: some View {
        if plan.capsule {
            Capsule().fill(Color.black.opacity(plan.background))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(plan.background))
        }
    }

    @ViewBuilder private var outline: some View {
        let line = editing ? BCDStyle.lavender.opacity(0.9) : Color.white.opacity(0.12)
        if plan.capsule {
            Capsule().strokeBorder(line, style: StrokeStyle(lineWidth: 1, dash: editing ? [4, 3] : []))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(line, style: StrokeStyle(lineWidth: 1, dash: editing ? [4, 3] : []))
        }
    }

    @ViewBuilder private var content: some View {
        if plan.columns == 2 {
            // Readings in two columns; a graph stands between two grids, not inside one.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tableChunks.enumerated()), id: \.offset) { _, chunk in
                    switch chunk {
                    case .lines(let rows):
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, parts in
                                GridRow { ForEach(Array(parts.enumerated()), id: \.offset) { _, part in segment(part) } }
                            }
                        }
                    case .graph(let graph):
                        BCDHUDSparkline(graph: graph)
                    }
                }
            }
            .frame(maxWidth: plan.maxWidth, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: plan.layout == .report ? 3 : 4) {
                ForEach(Array(plan.rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .line(let parts):
                        line(parts)
                    case .graph(let graph):
                        BCDHUDSparkline(graph: graph)
                    case .pulse(let number, let caption, let dot):
                        pulse(number, caption, dot)
                    }
                }
            }
            .frame(maxWidth: plan.maxWidth, alignment: .leading)
        }
    }

    private enum Chunk {
        case lines([[BCDHUDSegment]])
        case graph(BCDHUDGraph)
    }

    /// The plan's rows in runs: consecutive lines together (one grid, so the columns line up), a graph on its own.
    private var tableChunks: [Chunk] {
        var out: [Chunk] = [], run: [[BCDHUDSegment]] = []
        for row in plan.rows {
            switch row {
            case .line(let parts): run.append(parts)
            case .graph(let graph):
                if !run.isEmpty { out.append(.lines(run)); run = [] }
                out.append(.graph(graph))
            case .pulse: break
            }
        }
        if !run.isEmpty { out.append(.lines(run)) }
        return out
    }

    private var font: Font { .system(size: plan.textSize, weight: .semibold, design: .rounded).monospacedDigit() }

    private func segment(_ part: BCDHUDSegment) -> some View {
        Text(verbatim: part.text).font(font).foregroundColor(Self.color(part.tone)).lineLimit(1).fixedSize()
            .opacity(plan.textOpacity).modifier(BCDHUDOutline(on: plan.outlineText))
    }

    /// One line as one text: the readings in their colours, the layout's separator between them.
    private func line(_ parts: [BCDHUDSegment]) -> some View {
        var text = Text(verbatim: "")
        for (i, part) in parts.enumerated() {
            if i > 0 { text = text + Text(verbatim: plan.separator).foregroundColor(BCDStyle.textSoft.opacity(0.7)) }
            text = text + Text(verbatim: part.text).foregroundColor(Self.color(part.tone))
        }
        return text.font(font).lineLimit(1).minimumScaleFactor(0.75).opacity(plan.textOpacity).modifier(BCDHUDOutline(on: plan.outlineText))
    }

    private func pulse(_ number: BCDHUDSegment, _ caption: String, _ dot: BCDHUDTone?) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: number.text).font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit()).foregroundColor(Self.color(number.tone))
            Text(verbatim: caption).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(BCDStyle.textSoft)
            if let dot { Circle().fill(Self.color(dot)).frame(width: 6, height: 6).padding(.leading, 2) }
        }
        .lineLimit(1).fixedSize()
        .opacity(plan.textOpacity)
    }

    static func color(_ tone: BCDHUDTone) -> Color {
        switch tone {
        case .normal: return BCDSessionTone.normal.color
        case .soft: return BCDSessionTone.soft.color
        case .good: return BCDSessionTone.good.color
        case .warm: return BCDSessionTone.warm.color
        case .hot: return BCDSessionTone.hot.color
        }
    }
}

/// A thin dark edge round the letters, for a plate that is almost clear.
private struct BCDHUDOutline: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.shadow(color: .black.opacity(0.95), radius: 0.8).shadow(color: .black.opacity(0.7), radius: 1.6)
        } else {
            content
        }
    }
}

/// The frame-time graph: a line of the slowest frame of each quarter second, between guides at 16.7 and 33.3 ms (60 and 30 fps).
/// Spikes over 33 ms get a red dot. Drawn once per update; nothing in it moves by itself.
struct BCDHUDSparkline: View {
    let graph: BCDHUDGraph

    var body: some View {
        Canvas { context, size in
            let ceiling = CGFloat(max(graph.ceiling, 1))
            func y(_ ms: Float) -> CGFloat { size.height * (1 - min(max(CGFloat(ms), 0), ceiling) / ceiling) }
            for guide: Float in [16.7, 33.3] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y(guide)))
                path.addLine(to: CGPoint(x: size.width, y: y(guide)))
                context.stroke(path, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
            guard graph.values.count > 1 else { return }
            let step = size.width / CGFloat(graph.values.count - 1)
            var path = Path()
            var started = false
            var spikes: [CGPoint] = []
            for (i, value) in graph.values.enumerated() {
                guard value > 0 else { started = false; continue }   // before the first frame
                let point = CGPoint(x: CGFloat(i) * step, y: y(value))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                if value > 33.3 { spikes.append(point) }
            }
            context.stroke(path, with: .color(BCDHUDPanel.color(graph.tone)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            for point in spikes {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(BCDStyle.alert))
            }
        }
        .frame(width: graph.width, height: graph.height)
        .accessibilityHidden(true)
    }
}
