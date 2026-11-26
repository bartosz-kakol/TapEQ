//
//  PersistenceTests.swift
//  TapEQTests
//

import XCTest
@testable import TapEQ

final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: PersistentStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapEQTests-\(UUID().uuidString)", isDirectory: true)
        store = PersistentStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var samplePreset: Preset {
        Preset(
            name: "Desk speakers",
            preampDB: -4.5,
            bands: [
                Band(type: .highPass, frequency: 35, q: 0.707),
                Band(type: .lowShelf, frequency: 110, gain: 5.5, q: 0.8),
                Band(type: .peak, frequency: 2_400, gain: -3.25, q: 2.2, isEnabled: false),
                Band(type: .highShelf, frequency: 9_000, gain: 2),
                Band(type: .lowPass, frequency: 18_500, q: 0.6),
            ]
        )
    }

    private var sampleRules: RulesFile {
        RulesFile(
            rules: [
                .device(uid: "BuiltInSpeakerDevice", presetID: BuiltInPresets.bassBoost.id),
                .app(AppTarget(bundleID: "com.spotify.client", displayName: "Spotify"), presetID: samplePreset.id),
                .app(
                    AppTarget(bundleID: "com.apple.Safari", displayName: "Safari", extraBundleIDs: ["com.apple.WebKit.GPU"]),
                    onDevice: "AA-BB-CC:output",
                    presetID: nil
                ),
            ],
            knownDevices: [
                KnownDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"),
                KnownDevice(uid: "AA-BB-CC:output", name: "AirPods Max"),
            ]
        )
    }

    // MARK: - Round trips

    func testPresetsRoundTrip() throws {
        let file = PresetsFile(presets: [samplePreset, Preset(name: "Empty")])
        try store.save(file, to: .presets)
        let loaded = store.load(PresetsFile.self, from: .presets)
        XCTAssertEqual(loaded.outcome, .loaded)
        XCTAssertEqual(loaded.value, file)
    }

    func testRulesRoundTripIncludingNoneAndDisconnectedDevices() throws {
        let file = sampleRules
        try store.save(file, to: .rules)
        let loaded = store.load(RulesFile.self, from: .rules)
        XCTAssertEqual(loaded.outcome, .loaded)
        XCTAssertEqual(loaded.value, file)
        XCTAssertEqual(loaded.value?.rules.map(\.kind), [.device, .app, .appOnDevice])
        XCTAssertNil(loaded.value?.rules[2].presetID)

        // "None" is written out explicitly rather than left to a default.
        let text = try String(contentsOf: store.url(for: .rules), encoding: .utf8)
        XCTAssertTrue(text.contains("\"preset\" : null"))
    }

    func testSettingsRoundTrip() throws {
        let file = SettingsFile(bypassAll: true, showDockIcon: true)
        try store.save(file, to: .settings)
        XCTAssertEqual(store.load(SettingsFile.self, from: .settings).value, file)
    }

    func testOlderSettingsFileShowsPresetInMenuBar() throws {
        let decoded = try JSONDecoder().decode(SettingsFile.self, from: Data(#"{"version":1,"bypassAll":false}"#.utf8))
        XCTAssertTrue(decoded.showsPresetInMenuBar, "A file written before the setting existed gets the default")
    }

    func testMissingFilesLoadAsMissing() {
        let loaded = store.load(PresetsFile.self, from: .presets)
        XCTAssertNil(loaded.value)
        XCTAssertEqual(loaded.outcome, .missing)
    }

    // MARK: - Backups and recovery

    func testSavingKeepsThePreviousVersionAsBackup() throws {
        let first = PresetsFile(presets: [Preset(name: "First")])
        let second = PresetsFile(presets: [Preset(name: "Second")])
        let third = PresetsFile(presets: [Preset(name: "Third")])

        try store.save(first, to: .presets)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL(for: .presets).path))

        try store.save(second, to: .presets)
        try store.save(third, to: .presets)

        let backup = try JSONDecoder().decode(PresetsFile.self, from: Data(contentsOf: store.backupURL(for: .presets)))
        XCTAssertEqual(backup, second, "Exactly one backup: the version before the latest")
        XCTAssertEqual(store.load(PresetsFile.self, from: .presets).value, third)
    }

    func testSavingUnchangedDataDoesNotRotateTheBackup() throws {
        let first = PresetsFile(presets: [Preset(name: "First")])
        let second = PresetsFile(presets: [Preset(name: "Second")])
        try store.save(first, to: .presets)
        try store.save(second, to: .presets)
        try store.save(second, to: .presets)
        let backup = try JSONDecoder().decode(PresetsFile.self, from: Data(contentsOf: store.backupURL(for: .presets)))
        XCTAssertEqual(backup, first)
    }

    func testDamagedFileIsRecoveredFromBackup() throws {
        let first = sampleRules
        var second = sampleRules
        second.rules.removeLast()
        try store.save(first, to: .rules)
        try store.save(second, to: .rules)

        try Data("{ not json".utf8).write(to: store.url(for: .rules))
        let loaded = store.load(RulesFile.self, from: .rules)
        XCTAssertEqual(loaded.outcome, .recoveredFromBackup)
        XCTAssertEqual(loaded.value, first)

        // Saving over the damaged file must not replace the good backup with it.
        try store.save(second, to: .rules)
        let backup = try JSONDecoder().decode(RulesFile.self, from: Data(contentsOf: store.backupURL(for: .rules)))
        XCTAssertEqual(backup, first)
    }

    func testDamagedFileWithoutBackupIsReportedUnreadable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.url(for: .settings))
        let loaded = store.load(SettingsFile.self, from: .settings)
        XCTAssertNil(loaded.value)
        XCTAssertEqual(loaded.outcome, .unreadable)
    }

    func testNoTemporaryFilesAreLeftBehind() throws {
        try store.save(PresetsFile(presets: [samplePreset]), to: .presets)
        try store.save(PresetsFile(presets: []), to: .presets)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["presets.json", "presets.json.bak"])
    }

    // MARK: - Tolerant decoding

    func testDecodingClampsAndFillsDefaults() throws {
        let json = """
        { "presets": [ { "name": "  ", "preamp": 99, "bands": [
            { "type": "peak", "frequency": 5, "gain": -80, "q": 50 },
            { "frequency": 1000 }
        ] } ] }
        """
        let file = try JSONDecoder().decode(PresetsFile.self, from: Data(json.utf8))
        let preset = try XCTUnwrap(file.presets.first)
        XCTAssertEqual(preset.name, "Untitled")
        XCTAssertEqual(preset.preampDB, 12)
        XCTAssertEqual(preset.bands[0].frequency, 20)
        XCTAssertEqual(preset.bands[0].gain, -24)
        XCTAssertEqual(preset.bands[0].q, 10)
        XCTAssertEqual(preset.bands[1].type, .peak)
        XCTAssertTrue(preset.bands[1].isEnabled)
    }

    func testDecodingDropsBandsBeyondTheLimit() throws {
        let bands = (0..<20).map { _ in "{ \"type\": \"peak\", \"frequency\": 1000, \"gain\": 1, \"q\": 1 }" }
        let json = "{ \"name\": \"Many\", \"bands\": [\(bands.joined(separator: ","))] }"
        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.bands.count, EQLimits.maxBands)
    }

    // MARK: - Import and export

    func testExportedPresetImportsUnchanged() throws {
        let preset = samplePreset
        let data = try PersistentStore.exportData(for: preset)
        XCTAssertEqual(try PersistentStore.importPreset(from: data), preset)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "TapEQ preset")
    }

    func testBarePresetObjectImports() throws {
        let json = "{ \"name\": \"Bare\", \"preamp\": -2, \"bands\": [ { \"type\": \"lowShelf\", \"frequency\": 80, \"gain\": 4, \"q\": 0.7 } ] }"
        let preset = try PersistentStore.importPreset(from: Data(json.utf8))
        XCTAssertEqual(preset.name, "Bare")
        XCTAssertEqual(preset.preampDB, -2)
        XCTAssertEqual(preset.bands.first?.type, .lowShelf)
    }

    func testImportRejectsFilesThatAreNotPresets() {
        for text in ["[1, 2, 3]", "{ \"rules\": [] }", "{ \"name\": \"No bands\" }", "not json at all"] {
            XCTAssertThrowsError(try PersistentStore.importPreset(from: Data(text.utf8)), text)
        }
    }

    // MARK: - Built-ins

    func testBuiltInPresetsAreCompleteStableAndWithinHeadroom() {
        XCTAssertEqual(
            BuiltInPresets.all.map(\.name),
            ["Flat", "Bass Boost", "Bass Cut", "Vocal Presence", "Treble Boost", "Loudness"]
        )
        XCTAssertEqual(BuiltInPresets.ids.count, BuiltInPresets.all.count)
        for preset in BuiltInPresets.all {
            XCTAssertTrue(preset.isBuiltIn)
            XCTAssertEqual(preset, preset.sanitized(), "\(preset.name) is already within limits")
            XCTAssertLessThanOrEqual(preset.headroomDeficit, 0.1, "\(preset.name) must not clip a full-scale signal")
        }
        XCTAssertEqual(BuiltInPresets.flat.id.uuidString, "7A9E5100-0000-4000-8000-000000000001")

        let copy = BuiltInPresets.loudness.duplicated(named: "Loudness copy")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.bands.map(\.gain), BuiltInPresets.loudness.bands.map(\.gain))
        XCTAssertTrue(Set(copy.bands.map(\.id)).isDisjoint(with: BuiltInPresets.loudness.bands.map(\.id)))
    }
}
