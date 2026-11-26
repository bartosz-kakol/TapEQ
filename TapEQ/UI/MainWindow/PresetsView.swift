//
//  PresetsView.swift
//  TapEQ
//
//  The list of presets and the editor for the selected one.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PresetsView: View {
    @Environment(AppModel.self) private var model

    @State private var selection: UUID?
    @State private var presetToDelete: Preset?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            presetList
                .frame(width: 220)
            Divider()
            Group {
                if let preset = model.preset(selection) {
                    PresetEditor(preset: preset, onDuplicate: { duplicate(preset.id) }, onExport: { export(preset) })
                        // A fresh editor per preset, so band selection and
                        // text fields never carry over.
                        .id(preset.id)
                } else {
                    ContentUnavailableView(
                        "No Preset Selected",
                        systemImage: "slider.horizontal.3",
                        description: Text("Choose a preset on the left, or create a new one.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.preset(selection) == nil {
                // Start on something editable when there is something.
                selection = model.userPresets.first?.id ?? BuiltInPresets.flat.id
            }
        }
        .onChange(of: selection) { _, _ in
            // Auditioning belongs to the preset that was on screen.
            model.setAudition(nil)
        }
        .onDisappear {
            model.setAudition(nil)
        }
        .confirmationDialog(
            "Delete “\(presetToDelete?.name ?? "")”?",
            isPresented: Binding(get: { presetToDelete != nil }, set: { if !$0 { presetToDelete = nil } }),
            presenting: presetToDelete
        ) { preset in
            Button("Delete", role: .destructive) {
                if selection == preset.id { selection = BuiltInPresets.flat.id }
                model.deletePreset(preset.id)
            }
        } message: { preset in
            let count = model.ruleCount(usingPreset: preset.id)
            Text(count == 0
                 ? "This cannot be undone."
                 : "\(count) rule\(count == 1 ? " uses" : "s use") this preset. \(count == 1 ? "It" : "They") will stay, but will not apply any EQ until you pick another preset. This cannot be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: List

    private var presetList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Built-in") {
                    ForEach(BuiltInPresets.all) { preset in
                        row(for: preset)
                    }
                }
                Section("My Presets") {
                    if model.userPresets.isEmpty {
                        Text("None yet")
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(model.userPresets) { preset in
                        row(for: preset)
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("New Preset") { selection = model.addPreset().id }
                    Button("Duplicate Selected") {
                        if let selection { duplicate(selection) }
                    }
                    .disabled(model.preset(selection) == nil)
                    Divider()
                    Button("Import…") { importPreset() }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add, duplicate or import a preset")

                Button {
                    presetToDelete = model.preset(selection)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(model.preset(selection)?.isBuiltIn ?? true)
                .help("Delete the selected preset")

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private func row(for preset: Preset) -> some View {
        HStack(spacing: 6) {
            Text(preset.name)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.auditionPresetID == preset.id {
                Image(systemName: "ear")
                    .foregroundStyle(.orange)
                    .help("Being auditioned on the current output")
            }
        }
        .tag(UUID?.some(preset.id))
        .contextMenu {
            Button("Duplicate") { duplicate(preset.id) }
            Button("Export…") { export(preset) }
            if !preset.isBuiltIn {
                Divider()
                Button("Delete…", role: .destructive) { presetToDelete = preset }
            }
        }
    }

    // MARK: Actions

    private func duplicate(_ id: UUID) {
        if let copy = model.duplicatePreset(id) {
            selection = copy.id
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose preset files exported from TapEQ"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                selection = try model.importPreset(from: url).id
            } catch {
                errorMessage = "Could not import “\(url.lastPathComponent)”. \(error.localizedDescription)"
            }
        }
    }

    private func export(_ preset: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = preset.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportPreset(preset.id, to: url)
        } catch {
            errorMessage = "Could not export “\(preset.name)”. \(error.localizedDescription)"
        }
    }
}

// MARK: - Editor

struct PresetEditor: View {
    @Environment(AppModel.self) private var model

    let preset: Preset
    let onDuplicate: () -> Void
    let onExport: () -> Void

    @State private var selectedBandID: UUID?
    @State private var name = ""

    private var isEditable: Bool { !preset.isBuiltIn }
    private var isAuditioning: Bool { model.auditionPresetID == preset.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                FrequencyResponseGraph(
                    preset: preset,
                    isEditable: isEditable,
                    selectedBandID: $selectedBandID,
                    onChange: { model.updatePreset($0) }
                )
                .frame(height: 290)

                if isEditable {
                    Text("Drag a handle to set frequency and gain. Scroll or Option-drag to change Q. Double-click to add a band.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                headroomWarning
                preampRow
                BandTable(
                    preset: preset,
                    isEditable: isEditable,
                    selectedBandID: $selectedBandID,
                    onChange: { model.updatePreset($0) }
                )
            }
            .padding(20)
        }
        .onAppear { name = preset.name }
        .onChange(of: preset.name) { _, newValue in name = newValue }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isEditable {
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .frame(minWidth: 120, maxWidth: 280)
                    .onSubmit(commitName)
                    .onDisappear(perform: commitName)
            } else {
                Text(preset.name)
                    .font(.title2.weight(.semibold))
                Badge(text: "Built-in", color: .secondary)
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { isAuditioning },
                set: { model.setAudition($0 ? preset.id : nil) }
            )) {
                Label("Audition on current output", systemImage: "ear")
            }
            .toggleStyle(.button)
            .fixedSize()
            .disabled(model.engine.currentDevice == nil)
            .help("Applies this preset to the current output while this editor is open. Apps with their own rule or override keep it.")

            Button("Duplicate", action: onDuplicate)
                .fixedSize()
            Button("Export…", action: onExport)
                .fixedSize()
        }
        .overlay(alignment: .bottomLeading) {
            if !isEditable {
                Text("Built-in presets cannot be changed. Duplicate this one to make your own version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .offset(y: 18)
            }
        }
        .padding(.bottom, isEditable ? 0 : 14)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            name = preset.name
        } else {
            model.renamePreset(preset.id, to: trimmed)
        }
    }

    @ViewBuilder
    private var headroomWarning: some View {
        let deficit = preset.headroomDeficit
        if deficit > 0.05 {
            let suggested = (-EQCurve.peakBoost(bands: preset.bands) * 10).rounded(.down) / 10
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("The curve rises \(String(format: "%.1f", deficit)) dB above full scale, so loud passages will be soft-clipped. A preamp of \(String(format: "%.1f", suggested)) dB leaves enough headroom.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isEditable, suggested >= EQLimits.preamp.lowerBound {
                    Button("Set Preamp to \(String(format: "%.1f", suggested)) dB") {
                        var edited = preset
                        edited.preampDB = suggested
                        model.updatePreset(edited)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var preampRow: some View {
        let binding = Binding<Double>(
            get: { preset.preampDB },
            set: { newValue in
                var edited = preset
                edited.preampDB = (newValue * 10).rounded() / 10
                model.updatePreset(edited)
            }
        )
        return HStack(spacing: 12) {
            Text("Preamp")
                .frame(width: 60, alignment: .leading)
            Slider(value: binding, in: EQLimits.preamp) {
                Text("Preamp")
            } minimumValueLabel: {
                Text("−24").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("+12").font(.caption).foregroundStyle(.secondary)
            }
            .labelsHidden()
            TextField("Preamp", value: binding, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
            Text("dB")
                .foregroundStyle(.secondary)
        }
        .disabled(!isEditable)
    }
}

// MARK: - Band table

struct BandTable: View {
    let preset: Preset
    let isEditable: Bool
    @Binding var selectedBandID: UUID?
    let onChange: (Preset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bands")
                    .font(.headline)
                Text("\(preset.bands.count) of \(EQLimits.maxBands)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addBand()
                } label: {
                    Label("Add Band", systemImage: "plus")
                }
                .disabled(!isEditable || preset.bands.count >= EQLimits.maxBands)
            }

            if preset.bands.isEmpty {
                Text("This preset has no bands, so it only applies the preamp.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("#")
                        Text("On")
                        Text("Type")
                        Text("Frequency (Hz)")
                        Text("Gain (dB)")
                        Text("Q")
                        Text("")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(Array(preset.bands.enumerated()), id: \.element.id) { index, band in
                        row(index: index, band: band)
                    }
                }
            }
        }
    }

    private func binding<Value>(_ index: Int, _ keyPath: WritableKeyPath<Band, Value>) -> Binding<Value> {
        Binding(
            get: { preset.bands[index][keyPath: keyPath] },
            set: { newValue in
                guard preset.bands.indices.contains(index) else { return }
                var edited = preset
                edited.bands[index][keyPath: keyPath] = newValue
                edited.bands[index] = edited.bands[index].clamped()
                selectedBandID = edited.bands[index].id
                onChange(edited)
            }
        )
    }

    private func row(index: Int, band: Band) -> some View {
        let isSelected = band.id == selectedBandID
        return GridRow {
            Button {
                selectedBandID = band.id
            } label: {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: 20, height: 20)
                    .background(FrequencyResponseGraph.bandColors[index % EQLimits.maxBands], in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.7 : 0), lineWidth: 2).padding(-3))
            }
            .buttonStyle(.plain)
            .help("Select band \(index + 1) in the graph")

            Toggle("Band \(index + 1) enabled", isOn: binding(index, \.isEnabled))
                .labelsHidden()
                .toggleStyle(.checkbox)

            Picker("Type", selection: binding(index, \.type)) {
                ForEach(BandType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            TextField("Frequency", value: binding(index, \.frequency), format: .number.precision(.fractionLength(0...1)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)

            if band.type.usesGain {
                TextField("Gain", value: binding(index, \.gain), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
                    .help("Low-pass and high-pass bands have no gain")
            }

            TextField("Q", value: binding(index, \.q), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)

            Button {
                var edited = preset
                edited.bands.remove(at: index)
                if selectedBandID == band.id { selectedBandID = nil }
                onChange(edited)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove band \(index + 1)")
        }
        .disabled(!isEditable)
        .opacity(band.isEnabled ? 1 : 0.6)
    }

    private func addBand() {
        guard preset.bands.count < EQLimits.maxBands else { return }
        let band = Band(type: .peak, frequency: 1_000, gain: 0, q: 1)
        var edited = preset
        edited.bands.append(band)
        selectedBandID = band.id
        onChange(edited)
    }
}
