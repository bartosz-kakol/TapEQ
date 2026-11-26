//
//  Rule.swift
//  TapEQ
//
//  A rule binds a preset to a target: an output device, an app, or an app on
//  a specific output device.
//

import Foundation

/// The app a rule applies to.
struct AppTarget: Codable, Equatable, Sendable {
    /// Bundle identifier of the app. Helper processes whose identifier
    /// extends this one (`com.example.App.helper`) match as well.
    var bundleID: String
    /// Name shown in the UI when the app cannot be found on disk.
    var displayName: String
    /// Further identifiers that count as this app, for helpers whose
    /// identifier does not extend the app's own.
    var extraBundleIDs: [String]

    init(bundleID: String, displayName: String, extraBundleIDs: [String] = []) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.extraBundleIDs = extraBundleIDs
    }

    /// Every identifier this target matches, without blanks or duplicates.
    var allBundleIDs: [String] {
        var seen = Set<String>()
        return ([bundleID] + extraBundleIDs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID, displayName = "name", extraBundleIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? bundleID
        extraBundleIDs = try container.decodeIfPresent([String].self, forKey: .extraBundleIDs) ?? []
    }
}

struct Rule: Codable, Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Applies while the device is the system default output.
        case device
        /// Applies whenever the app plays audio.
        case app
        /// Applies when the app plays audio on one particular device.
        case appOnDevice
    }

    var id: UUID
    /// The app this rule is about, or nil for a device rule.
    var app: AppTarget?
    /// UID of the output device this rule is tied to, or nil for any device.
    var deviceUID: String?
    /// The preset to apply. Nil means "None": this target is explicitly
    /// never equalized, and resolution stops here.
    var presetID: UUID?

    init(id: UUID = UUID(), app: AppTarget? = nil, deviceUID: String? = nil, presetID: UUID?) {
        self.id = id
        self.app = app
        self.deviceUID = deviceUID
        self.presetID = presetID
    }

    static func device(uid: String, presetID: UUID?) -> Rule {
        Rule(deviceUID: uid, presetID: presetID)
    }

    static func app(_ app: AppTarget, onDevice deviceUID: String? = nil, presetID: UUID?) -> Rule {
        Rule(app: app, deviceUID: deviceUID, presetID: presetID)
    }

    /// Nil for a rule with neither an app nor a device, which matches nothing.
    var kind: Kind? {
        switch (app, deviceUID) {
        case (nil, nil): return nil
        case (nil, .some): return .device
        case (.some, nil): return .app
        case (.some, .some): return .appOnDevice
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, app, deviceUID, presetID = "preset"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        app = try container.decodeIfPresent(AppTarget.self, forKey: .app)
        deviceUID = try container.decodeIfPresent(String.self, forKey: .deviceUID)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encodeIfPresent(deviceUID, forKey: .deviceUID)
        // Written even when nil, so "None" is visible in the file.
        try container.encode(presetID, forKey: .presetID)
    }
}

/// An output device the app has seen, remembered so its rules can be shown
/// and edited while it is disconnected.
struct KnownDevice: Codable, Identifiable, Equatable, Sendable {
    /// The device's persistent UID.
    var uid: String
    /// The name the device had when it was last connected.
    var name: String

    var id: String { uid }
}
