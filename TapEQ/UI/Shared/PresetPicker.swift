//
//  PresetPicker.swift
//  TapEQ
//
//  A pop-up for choosing "None" or one of the presets.
//

import SwiftUI

struct PresetPicker: View {
    @Environment(AppModel.self) private var model

    let title: String
    @Binding var selection: UUID?
    /// What the "no preset" choice is called here.
    var noneLabel = "None"

    var body: some View {
        Picker(title, selection: $selection) {
            Text(noneLabel).tag(UUID?.none)
            Divider()
            Section("Built-in") {
                ForEach(BuiltInPresets.all) { preset in
                    Text(preset.name).tag(UUID?.some(preset.id))
                }
            }
            if !model.userPresets.isEmpty {
                Section("My Presets") {
                    ForEach(model.userPresets) { preset in
                        Text(preset.name).tag(UUID?.some(preset.id))
                    }
                }
            }
            if let selection, model.preset(selection) == nil {
                // The rule still points at a preset that was deleted. Show
                // that, rather than silently displaying something else.
                Divider()
                Text("Deleted preset").tag(UUID?.some(selection))
            }
        }
    }
}

/// A small rounded label, used for "Override", "Built-in" and the like.
struct Badge: View {
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
