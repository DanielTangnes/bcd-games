// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// Quick picks under a game's Launch arguments (round 604, Winlator's "extra arguments" menu in BCD's own look): each is a flag that
// goes into the text when tapped and out again when tapped a second time; the ones that rule each other out (one Direct3D version,
// window or full screen) take each other out (BCDLaunchFlags.toggled). The text is the page's draft: nothing is saved until Save.
// A row, not a lazy grid, for every pick: a controller's focus needs every one laid out to find its neighbours.

struct BCDGameChipGrid: View {
    let chips: [BCDGameChip]
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BCDEyebrow(text: "Quick picks").padding(.leading, 4)
            ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in row(chip, index) }
        }
    }

    private func row(_ chip: BCDGameChip, _ index: Int) -> some View {
        let on = BCDLaunchFlags.has(text, chip.value)
        let id = "game.panel.chip.\(index)"
        let toggle = { text = BCDLaunchFlags.toggled(text, chip.value) }
        return Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(on ? AnyShapeStyle(BCDStyle.glow) : AnyShapeStyle(BCDStyle.textSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.value).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(BCDStyle.text)
                    Text(chip.note).font(BCDStyle.body(12)).foregroundStyle(BCDStyle.textSoft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? BCDStyle.surfaceRaised : BCDStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .bcdFocusable(id, cornerRadius: 14, action: toggle)
        .id(id)
        .accessibilityLabel(chip.value + ", " + chip.note)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
