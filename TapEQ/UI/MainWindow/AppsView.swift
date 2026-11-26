//
//  AppsView.swift
//  TapEQ
//
//  Rules for individual apps: which preset an app gets, optionally only on
//  one output device.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.appRules.isEmpty {
                    Text("No app rules yet. Add an app to give it its own preset, or to keep it from being equalized at all.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.appRules) { rule in
                    AppRuleRow(rule: rule)
                }
            } header: {
                HStack {
                    Text("App Rules")
                    Spacer()
                    addMenu
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("An app rule wins over the output device's preset. A rule tied to a device wins over a rule for any device. “None” means the app is never equalized.")
                    Text("Many apps play sound from helper processes. A rule also covers helpers whose bundle ID extends the app's (com.google.Chrome covers com.google.Chrome.helper). For helpers named differently, add their bundle IDs under “Also match”.")
                    Text("Safari and other WebKit-based apps all play through the shared process com.apple.WebKit.GPU, so a rule that matches it affects web audio in every such app at once.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var addMenu: some View {
        Menu {
            let playing = model.engine.playingApps
            if !playing.isEmpty {
                Section("Playing Now") {
                    ForEach(playing) { app in
                        Button {
                            model.addAppRule(bundleID: app.id, displayName: app.name)
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: AppIcons.icon(bundleID: app.id, bundleURL: app.bundleURL))
                            }
                        }
                    }
                }
            }
            Button("Choose Application…") { chooseApplication() }
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.message = "Choose the apps to add rules for"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            model.addAppRule(bundleID: bundleID, displayName: FileManager.default.displayName(atPath: url.path))
        }
    }
}

private struct AppRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule

    @State private var extraIDsText = ""

    private var app: AppTarget { rule.app ?? AppTarget(bundleID: "", displayName: "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIconView(bundleID: app.bundleID, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppIcons.displayName(bundleID: app.bundleID) ?? app.displayName)
                        .font(.headline)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(role: .destructive) {
                    model.deleteRule(rule.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this rule")
            }

            LabeledContent("Preset") {
                PresetPicker(
                    title: "Preset",
                    selection: Binding(
                        get: { rule.presetID },
                        set: { newValue in
                            var edited = rule
                            edited.presetID = newValue
                            model.updateRule(edited)
                        }
                    ),
                    noneLabel: "None (never equalize)"
                )
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Only on") {
                Picker("Only on device", selection: Binding(
                    get: { rule.deviceUID },
                    set: { newValue in
                        var edited = rule
                        edited.deviceUID = newValue
                        model.updateRule(edited)
                    }
                )) {
                    Text("Any output device").tag(String?.none)
                    Divider()
                    ForEach(model.knownDevices) { device in
                        Text(model.isConnected(deviceUID: device.uid) ? device.name : "\(device.name) (not connected)")
                            .tag(String?.some(device.uid))
                    }
                    if let uid = rule.deviceUID, !model.knownDevices.contains(where: { $0.uid == uid }) {
                        Text(uid).tag(String?.some(uid))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent("Also match") {
                TextField("Also match", text: $extraIDsText, prompt: Text("Extra bundle IDs, separated by commas"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 380)
                    .onSubmit(commitExtraIDs)
            }

            if model.isShadowed(rule) {
                Label("An earlier rule has the same app and device, so this one never applies.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if app.allBundleIDs.contains(AppIdentityResolver.webKitAudioBundleID) {
                Label("Matches com.apple.WebKit.GPU: web audio from Safari and every other WebKit-based app gets this preset.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { extraIDsText = app.extraBundleIDs.joined(separator: ", ") }
        .onDisappear(perform: commitExtraIDs)
    }

    private func commitExtraIDs() {
        let ids = extraIDsText
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map(String.init)
        guard var target = rule.app, target.extraBundleIDs != ids else { return }
        target.extraBundleIDs = ids
        var edited = rule
        edited.app = target
        model.updateRule(edited)
        extraIDsText = ids.joined(separator: ", ")
    }
}
