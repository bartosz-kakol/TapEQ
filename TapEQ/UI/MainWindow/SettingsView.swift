//
//  SettingsView.swift
//  TapEQ
//
//  General settings, the state of the audio capture permission, and
//  diagnostics for the audio engine.
//

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    private var engine: AudioEngine { model.engine }

    var body: some View {
        @Bindable var model = model

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchesAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
                Toggle(isOn: $model.showsPresetInMenuBar) {
                    Text("Show preset name in the menu bar")
                    Text("The preset applied to the current output appears next to the icon. Nothing is shown while no preset applies.")
                }
            }

            Section("Audio Capture Permission") {
                permissionStatus
                Button("Open Privacy & Security Settings…") {
                    SystemSettings.openAudioCapturePrivacy()
                }
            }

            Section {
                Toggle("Reduce delay on Bluetooth outputs", isOn: $model.trimsBluetoothLatency)
                ForEach(model.latencyTrimDisabledDeviceUIDs, id: \.self) { uid in
                    Label("Switched off for \(model.deviceName(forUID: uid)) after a problem. Turn the setting off and on again to retry.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Bluetooth Latency (Experimental)")
            } footer: {
                Text("macOS delays captured audio by the latency a Bluetooth device reports (160 ms for AirPods Max), on top of the device's real delay, which puts equalized sound behind the picture in videos. This setting cancels that delay. It relies on the device reporting its latency accurately: if it does not, the system's audio service can restart, interrupting all sound for a moment. TapEQ then switches the setting off for that device.")
            }

            Section("Engine") {
                diagnostics
            }

            Section("Data") {
                LabeledContent("Presets and rules") {
                    Button("Show in Finder") {
                        let directory = PersistentStore.standard.directory
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Could not \(enabled ? "add" : "remove") the login item: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Permission

    @ViewBuilder
    private var permissionStatus: some View {
        switch engine.permission {
        case .granted:
            Label("Allowed. TapEQ is receiving audio from other apps.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unknown:
            VStack(alignment: .leading, spacing: 4) {
                Label("Not checked yet", systemImage: "questionmark.circle")
                Text("macOS offers no way to ask whether capture is allowed. TapEQ finds out the first time an app that should be equalized plays sound: it listens without changing anything, and only starts equalizing once audio arrives. The first time, macOS asks for your permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .suspectedDenied:
            VStack(alignment: .leading, spacing: 4) {
                Label("Probably not allowed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Apps are playing, but TapEQ receives only silence. Nothing is being equalized and nothing is muted. In Privacy & Security, allow TapEQ under “System Audio Recording Only” (in Screen & System Audio Recording), then quit and reopen TapEQ. If the apps really are playing silence, this message goes away as soon as they make a sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnostics: some View {
        let info = engine.diagnostics

        LabeledContent("State", value: engine.phase.displayName)
        LabeledContent("Output device", value: engine.currentDevice.map { "\($0.name)  (\($0.uid))" } ?? "None")

        if let aggregateID = info.aggregateID, let uid = info.aggregateUID {
            LabeledContent("Aggregate device") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(info.mode), object \(aggregateID), private")
                    Text(uid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Sample rate", value: String(format: "%.0f Hz", info.sampleRate))
            LabeledContent("Buffer size", value: "\(info.bufferFrameSize) frames")
            LabeledContent("Added delay") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f ms", (info.graphLatency + info.tapLatency) * 1000))
                    Text(String(format: "%.0f ms in the graph, %.0f ms tap latency%@",
                                info.graphLatency * 1000, info.tapLatency * 1000,
                                info.latencyTrimFrames > 0 ? " (trimmed by \(info.latencyTrimFrames) frames)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Channels", value: "in \(info.inputLayout), out \(info.outputLayout)")
            LabeledContent("Output level", value: Self.level(info.outputPeak))
            if info.layoutMismatches > 0 {
                LabeledContent("Buffer layout mismatches", value: "\(info.layoutMismatches)")
            }
            ForEach(info.taps) { tap in
                LabeledContent("Tap \(tap.id)") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(tap.presetName), input \(Self.level(tap.inputPeak))")
                        Text(tap.scope)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        if tap.silentSeconds > 1 {
                            Text(String(format: "silent for %.0f s", tap.silentSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            LabeledContent("Taps", value: "None")
            LabeledContent("Aggregate device", value: "None")
        }
        if !info.lastBuild.isEmpty {
            LabeledContent("Last build", value: info.lastBuild)
        }

        LabeledContent("Watchdog events") {
            if engine.watchdogEvents.isEmpty {
                Text("None")
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(engine.watchdogEvents, id: \.self) { event in
                        Text(event).font(.caption)
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Engine log")
                Text("last \(engine.logLines.count) lines")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rebuild Now") { engine.rebuild() }
                    .help("Destroys the taps and the aggregate device and builds them again")
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.logLines.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(engine.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                .onChange(of: engine.logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
                .onAppear {
                    if !engine.logLines.isEmpty { proxy.scrollTo(engine.logLines.count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private static func level(_ peak: Float) -> String {
        guard peak > 0 else { return "silent" }
        return String(format: "%.1f dBFS peak", 20 * log10(Double(peak)))
    }
}
