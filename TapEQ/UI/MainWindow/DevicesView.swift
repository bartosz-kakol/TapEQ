//
//  DevicesView.swift
//  TapEQ
//
//  One row per output device, connected or remembered, with the preset that
//  applies while it is the default output.
//

import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let uid: String
        let name: String
        let symbolName: String
        let isConnected: Bool
        let isCurrent: Bool
        var id: String { uid }
    }

    private var rows: [Row] {
        let engine = model.engine
        let connected = engine.devices.map { device in
            Row(uid: device.uid, name: device.name, symbolName: device.symbolName,
                isConnected: true, isCurrent: device.uid == engine.currentDevice?.uid)
        }
        let connectedUIDs = Set(connected.map(\.uid))
        let remembered = model.knownDevices
            .filter { !connectedUIDs.contains($0.uid) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Row(uid: $0.uid, name: $0.name, symbolName: "hifispeaker", isConnected: false, isCurrent: false) }
        return connected + remembered
    }

    var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    deviceRow(row)
                }
            } header: {
                Text("Output Devices")
            } footer: {
                Text("A device's preset applies to everything playing on it while it is the system's default output, except apps that have their own rule or override. Rules for disconnected devices are kept and apply again when the device returns.")
            }
        }
        .formStyle(.grouped)
    }

    private func deviceRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbolName)
                .font(.title3)
                .foregroundStyle(row.isConnected ? .primary : .tertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                    if row.isCurrent {
                        Badge(text: "Current output", color: .green)
                    }
                }
                Text(row.isConnected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            PresetPicker(
                title: "Preset for \(row.name)",
                selection: Binding(
                    get: { model.deviceRule(forUID: row.uid)?.presetID },
                    set: { model.setDevicePreset($0, forDeviceUID: row.uid) }
                )
            )
            .labelsHidden()
            .fixedSize()

            // The space is kept for connected devices too, so the pickers
            // line up down the column.
            Button {
                model.forgetDevice(uid: row.uid)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Forget this device and remove its rules")
            .opacity(row.isConnected ? 0 : 1)
            .disabled(row.isConnected)
            .accessibilityHidden(row.isConnected)
        }
        .padding(.vertical, 2)
    }
}
