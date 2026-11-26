//
//  Persistence.swift
//  TapEQ
//
//  Presets, rules and settings as JSON files in
//  ~/Library/Application Support/TapEQ/. Every write is atomic, and the
//  previous version of each file is kept as a single backup.
//

import Foundation

/// The contents of `presets.json`: the user's own presets. Built-ins are
/// part of the app and are never written to disk.
struct PresetsFile: Codable, Equatable {
    var version = 1
    var presets: [Preset] = []

    private enum CodingKeys: String, CodingKey { case version, presets }

    init(presets: [Preset] = []) {
        self.presets = presets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        presets = try container.decodeIfPresent([Preset].self, forKey: .presets) ?? []
    }
}

/// The contents of `rules.json`.
struct RulesFile: Codable, Equatable {
    var version = 1
    var rules: [Rule] = []
    var knownDevices: [KnownDevice] = []

    private enum CodingKeys: String, CodingKey { case version, rules, knownDevices }

    init(rules: [Rule] = [], knownDevices: [KnownDevice] = []) {
        self.rules = rules
        self.knownDevices = knownDevices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        knownDevices = try container.decodeIfPresent([KnownDevice].self, forKey: .knownDevices) ?? []
    }
}

/// The contents of `settings.json`.
struct SettingsFile: Codable, Equatable {
    var version = 1
    var bypassAll = false
    var showDockIcon = false
    /// Show the name of the effective preset next to the menu bar glyph.
    var showsPresetInMenuBar = true
    /// Cancel the system's latency compensation for taps on Bluetooth
    /// outputs. Off unless the user turns it on.
    var trimsBluetoothLatency = false
    /// Devices on which the trim caused trouble and is no longer used.
    var latencyTrimDisabledDeviceUIDs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case version, bypassAll, showDockIcon, showsPresetInMenuBar, trimsBluetoothLatency, latencyTrimDisabledDeviceUIDs
    }

    init(
        bypassAll: Bool = false,
        showDockIcon: Bool = false,
        showsPresetInMenuBar: Bool = true,
        trimsBluetoothLatency: Bool = false,
        latencyTrimDisabledDeviceUIDs: [String] = []
    ) {
        self.bypassAll = bypassAll
        self.showDockIcon = showDockIcon
        self.showsPresetInMenuBar = showsPresetInMenuBar
        self.trimsBluetoothLatency = trimsBluetoothLatency
        self.latencyTrimDisabledDeviceUIDs = latencyTrimDisabledDeviceUIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bypassAll = try container.decodeIfPresent(Bool.self, forKey: .bypassAll) ?? false
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        showsPresetInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showsPresetInMenuBar) ?? true
        trimsBluetoothLatency = try container.decodeIfPresent(Bool.self, forKey: .trimsBluetoothLatency) ?? false
        latencyTrimDisabledDeviceUIDs = try container.decodeIfPresent([String].self, forKey: .latencyTrimDisabledDeviceUIDs) ?? []
    }
}

/// A single preset on its own, as written by "Export…".
struct PresetExport: Encodable {
    var format = PresetExport.formatName
    var version = 1
    var preset: Preset

    static let formatName = "TapEQ preset"
}

enum PresetImportError: LocalizedError {
    case notAPreset

    var errorDescription: String? {
        "This file does not contain a TapEQ preset."
    }
}

/// Reads and writes the app's files in one directory.
struct PersistentStore {
    enum File: String, CaseIterable {
        case presets = "presets.json"
        case rules = "rules.json"
        case settings = "settings.json"
    }

    /// What `load` found on disk.
    enum LoadOutcome: Equatable {
        /// There is no file yet.
        case missing
        case loaded
        /// The file could not be read; the backup was used instead.
        case recoveredFromBackup
        /// Neither the file nor its backup could be read.
        case unreadable
    }

    let directory: URL

    /// The store in the user's Application Support folder, or in the folder
    /// named by `TAPEQ_DATA_DIR` when that is set (used by tests and by
    /// development runs that should not touch real data).
    static var standard: PersistentStore {
        if let override = ProcessInfo.processInfo.environment["TAPEQ_DATA_DIR"], !override.isEmpty {
            return PersistentStore(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        if AppEnvironment.isRunningTests {
            // The app hosting the unit tests must never read or write the
            // user's real data.
            return PersistentStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TapEQ-test-host-\(getpid())", isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return PersistentStore(directory: base.appendingPathComponent("TapEQ", isDirectory: true))
    }

    func url(for file: File) -> URL {
        directory.appendingPathComponent(file.rawValue)
    }

    func backupURL(for file: File) -> URL {
        directory.appendingPathComponent(file.rawValue + ".bak")
    }

    // MARK: Reading

    /// Loads a file, falling back to its backup when the file is damaged.
    /// Returns nil for the value when there is nothing usable.
    func load<Value: Decodable>(_ type: Value.Type, from file: File) -> (value: Value?, outcome: LoadOutcome) {
        let fileManager = FileManager.default
        let primary = url(for: file)
        let backup = backupURL(for: file)
        let primaryExists = fileManager.fileExists(atPath: primary.path)

        if primaryExists, let value = decode(type, at: primary) {
            return (value, .loaded)
        }
        if fileManager.fileExists(atPath: backup.path), let value = decode(type, at: backup) {
            return (value, .recoveredFromBackup)
        }
        return (nil, primaryExists ? .unreadable : .missing)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Writing

    /// Writes a file atomically. The version it replaces becomes the backup,
    /// unless that version is unreadable, in which case the existing backup
    /// is worth more and is kept.
    func save<Value: Codable>(_ value: Value, to file: File) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try Self.encoder.encode(value)
        let destination = url(for: file)
        let backup = backupURL(for: file)

        if let existing = try? Data(contentsOf: destination) {
            if existing == data { return }
            if (try? JSONDecoder().decode(Value.self, from: existing)) != nil {
                try existing.write(to: backup, options: .atomic)
            }
        }
        try data.write(to: destination, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: Preset import and export

    static func exportData(for preset: Preset) throws -> Data {
        try encoder.encode(PresetExport(preset: preset))
    }

    /// Reads a preset from an exported file. A bare preset object, without
    /// the export wrapper, is accepted too. The result keeps the identifier
    /// from the file; the caller decides whether to assign a new one.
    static func importPreset(from data: Data) throws -> Preset {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresetImportError.notAPreset
        }
        let payload = object["preset"] as? [String: Any] ?? object
        // Preset decoding is forgiving, so insist on the one field that
        // makes an object recognisably a preset.
        guard payload["bands"] is [Any] else {
            throw PresetImportError.notAPreset
        }
        return try JSONDecoder().decode(Preset.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
