//
//  AppModelTests.swift
//  TapEQTests
//
//  The model on its own, with a throwaway data folder and an engine that is
//  never started.
//

import XCTest
@testable import TapEQ

@MainActor
final class AppModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapEQModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel() -> AppModel {
        AppModel(store: PersistentStore(directory: directory))
    }

    func testFreshModelHasBuiltInsOnlyAndReportsFirstLaunch() {
        let model = makeModel()
        XCTAssertTrue(model.isFirstLaunch)
        XCTAssertEqual(model.presets, BuiltInPresets.all)
        XCTAssertTrue(model.rules.isEmpty)
        XCTAssertFalse(model.bypassAll)
        XCTAssertFalse(model.showDockIcon, "The Dock icon is hidden by default")
        XCTAssertTrue(model.showsPresetInMenuBar, "The preset name is shown by default")
        XCTAssertFalse(model.trimsBluetoothLatency, "The latency trim is opt-in")
        XCTAssertTrue(model.loadWarnings.isEmpty)
    }

    func testEverythingSurvivesARestart() throws {
        let model = makeModel()
        var preset = model.addPreset()
        preset.preampDB = -3
        preset.bands = [Band(type: .lowShelf, frequency: 90, gain: 4)]
        model.updatePreset(preset)
        model.renamePreset(preset.id, to: "Kitchen radio")
        model.setDevicePreset(preset.id, forDeviceUID: "BuiltInSpeakerDevice")
        var rule = model.addAppRule(bundleID: "com.spotify.client", displayName: "Spotify")
        rule.presetID = BuiltInPresets.bassCut.id
        rule.deviceUID = "AA:output"
        model.updateRule(rule)
        model.bypassAll = true
        model.showDockIcon = true
        model.showsPresetInMenuBar = false
        model.trimsBluetoothLatency = true
        model.setOverride(.device(uid: "BuiltInSpeakerDevice"), presetID: nil, lifetime: .untilCleared)
        model.flush()

        let reloaded = makeModel()
        XCTAssertFalse(reloaded.isFirstLaunch)
        XCTAssertEqual(reloaded.userPresets.count, 1)
        XCTAssertEqual(reloaded.userPresets.first?.name, "Kitchen radio")
        XCTAssertEqual(reloaded.userPresets.first?.preampDB, -3)
        XCTAssertEqual(reloaded.userPresets.first?.bands.first?.gain, 4)
        XCTAssertEqual(reloaded.deviceRule(forUID: "BuiltInSpeakerDevice")?.presetID, preset.id)
        XCTAssertEqual(reloaded.appRules.count, 1)
        XCTAssertEqual(reloaded.appRules.first?.kind, .appOnDevice)
        XCTAssertEqual(reloaded.appRules.first?.presetID, BuiltInPresets.bassCut.id)
        XCTAssertTrue(reloaded.bypassAll)
        XCTAssertTrue(reloaded.showDockIcon)
        XCTAssertFalse(reloaded.showsPresetInMenuBar)
        XCTAssertTrue(reloaded.trimsBluetoothLatency)
        XCTAssertTrue(reloaded.overrides.isEmpty, "Overrides are never written to disk")
    }

    // MARK: Menu bar text

    private func playing(_ id: String, _ presetID: UUID?, source: PresetSource = .appRule, otherDevice: Bool = false) -> PlayingApp {
        PlayingApp(id: id, name: id, bundleURL: nil, note: nil,
                   resolution: Resolution(presetID: presetID, source: source), isOnOtherDevice: otherDevice)
    }

    private func menuBarText(
        bypassAll: Bool = false,
        device: Resolution = .unmatched,
        apps: [PlayingApp] = []
    ) -> String? {
        let names = Dictionary(uniqueKeysWithValues: BuiltInPresets.all.map { ($0.id, $0.name) })
        return AppModel.menuBarPresetText(bypassAll: bypassAll, deviceResolution: device, playingApps: apps) { names[$0] }
    }

    func testMenuBarTextShowsTheOutputPresetFirst() {
        let device = Resolution(presetID: BuiltInPresets.bassBoost.id, source: .deviceRule)
        XCTAssertEqual(menuBarText(device: device, apps: [playing("a", BuiltInPresets.bassCut.id)]),
                       BuiltInPresets.bassBoost.name)
    }

    func testMenuBarTextIsEmptyWhenNothingIsEqualized() {
        XCTAssertNil(menuBarText())
        XCTAssertNil(menuBarText(device: Resolution(presetID: nil, source: .deviceRule), apps: [playing("a", nil)]))
        XCTAssertNil(menuBarText(apps: [playing("a", BuiltInPresets.bassCut.id, otherDevice: true)]),
                     "An app on another device is not equalized")
        XCTAssertNil(menuBarText(bypassAll: true, device: Resolution(presetID: BuiltInPresets.bassBoost.id, source: .deviceRule)))
    }

    func testMenuBarTextFallsBackToPlayingApps() {
        XCTAssertEqual(menuBarText(apps: [playing("a", BuiltInPresets.bassCut.id), playing("b", BuiltInPresets.bassCut.id)]),
                       BuiltInPresets.bassCut.name)
        XCTAssertEqual(menuBarText(apps: [playing("a", BuiltInPresets.bassCut.id), playing("b", BuiltInPresets.bassBoost.id)]),
                       "2 presets")
    }

    func testMenuBarTextTruncatesLongNames() {
        XCTAssertEqual(AppModel.truncatedForMenuBar("Short"), "Short")
        let long = AppModel.truncatedForMenuBar(String(repeating: "x", count: 40))
        XCTAssertEqual(long.count, 24)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testMenuBarTextRespectsTheSetting() {
        let model = makeModel()
        model.showsPresetInMenuBar = false
        XCTAssertNil(model.menuBarPresetText)
    }

    func testBuiltInPresetsCannotBeChangedRenamedOrDeleted() {
        let model = makeModel()
        var edited = BuiltInPresets.bassBoost
        edited.preampDB = 6
        edited.bands = []
        model.updatePreset(edited)
        model.renamePreset(BuiltInPresets.bassBoost.id, to: "Mine")
        model.deletePreset(BuiltInPresets.bassBoost.id)
        XCTAssertEqual(model.preset(BuiltInPresets.bassBoost.id), BuiltInPresets.bassBoost)
        XCTAssertTrue(model.userPresets.isEmpty)
    }

    func testDuplicatingABuiltInGivesAnEditableCopy() throws {
        let model = makeModel()
        let copy = try XCTUnwrap(model.duplicatePreset(BuiltInPresets.loudness.id))
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.name, "Loudness copy")
        XCTAssertEqual(copy.bands.count, BuiltInPresets.loudness.bands.count)
        XCTAssertEqual(try XCTUnwrap(model.duplicatePreset(BuiltInPresets.loudness.id)).name, "Loudness copy 2")
    }

    func testEditsAreClampedToTheLimits() throws {
        let model = makeModel()
        var preset = model.addPreset()
        preset.preampDB = 40
        preset.bands = (0..<20).map { _ in Band(type: .peak, frequency: 99_999, gain: -99, q: 99) }
        model.updatePreset(preset)
        let stored = try XCTUnwrap(model.preset(preset.id))
        XCTAssertEqual(stored.preampDB, 12)
        XCTAssertEqual(stored.bands.count, EQLimits.maxBands)
        XCTAssertEqual(stored.bands[0].frequency, 20_000)
        XCTAssertEqual(stored.bands[0].gain, -24)
        XCTAssertEqual(stored.bands[0].q, 10)
    }

    func testDeletingAPresetLeavesItsRulesInPlaceButUnnamed() {
        let model = makeModel()
        let preset = model.addPreset()
        model.setDevicePreset(preset.id, forDeviceUID: "D")
        XCTAssertEqual(model.ruleCount(usingPreset: preset.id), 1)
        model.deletePreset(preset.id)
        XCTAssertEqual(model.deviceRule(forUID: "D")?.presetID, preset.id)
        XCTAssertEqual(model.presetName(preset.id), "Deleted preset")
        XCTAssertEqual(model.presetName(nil), "None")
    }

    func testDevicePresetOfNoneRemovesTheRule() {
        let model = makeModel()
        model.setDevicePreset(BuiltInPresets.flat.id, forDeviceUID: "D")
        model.setDevicePreset(BuiltInPresets.bassCut.id, forDeviceUID: "D")
        XCTAssertEqual(model.deviceRules.count, 1)
        XCTAssertEqual(model.deviceRule(forUID: "D")?.presetID, BuiltInPresets.bassCut.id)
        model.setDevicePreset(nil, forDeviceUID: "D")
        XCTAssertNil(model.deviceRule(forUID: "D"))
    }

    func testImportAlwaysCreatesANewPresetAndExportRoundTrips() throws {
        let model = makeModel()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("export.json")
        try model.exportPreset(BuiltInPresets.vocalPresence.id, to: url)

        let first = try model.importPreset(from: url)
        let second = try model.importPreset(from: url)
        XCTAssertFalse(first.isBuiltIn)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.name, "Vocal Presence 2")
        XCTAssertEqual(second.name, "Vocal Presence 3")
        XCTAssertEqual(first.preampDB, BuiltInPresets.vocalPresence.preampDB)
        XCTAssertEqual(first.bands.map(\.frequency), BuiltInPresets.vocalPresence.bands.map(\.frequency))
        XCTAssertEqual(model.preset(BuiltInPresets.vocalPresence.id), BuiltInPresets.vocalPresence)
    }

    func testAddingSafariSuggestsTheWebKitAudioProcess() {
        let model = makeModel()
        let rule = model.addAppRule(bundleID: "com.apple.Safari", displayName: "Safari")
        XCTAssertEqual(rule.app?.extraBundleIDs, ["com.apple.WebKit.GPU"])
        XCTAssertNil(rule.presetID)
        XCTAssertEqual(model.addAppRule(bundleID: "com.spotify.client", displayName: "Spotify").app?.extraBundleIDs, [])
    }

    func testASecondRuleForTheSameAppAndDeviceIsFlaggedAsShadowed() {
        let model = makeModel()
        let first = model.addAppRule(bundleID: "com.spotify.client", displayName: "Spotify")
        var second = model.addAppRule(bundleID: "com.spotify.client", displayName: "Spotify")
        XCTAssertFalse(model.isShadowed(first))
        XCTAssertTrue(model.isShadowed(second))
        second.deviceUID = "D"
        model.updateRule(second)
        XCTAssertFalse(model.isShadowed(second))
    }

    func testOverridesAndAudition() {
        let model = makeModel()
        XCTAssertFalse(model.hasActiveOverride)
        model.setOverride(.app(bundleID: "a"), presetID: BuiltInPresets.flat.id, lifetime: .oneHour)
        model.setOverride(.device(uid: "D"), presetID: nil, lifetime: .untilDeviceChange)
        XCTAssertTrue(model.hasActiveOverride)
        XCTAssertEqual(model.override(for: .app(bundleID: "a"))?.lifetime, .oneHour)
        model.clearOverride(.app(bundleID: "a"))
        XCTAssertNil(model.override(for: .app(bundleID: "a")))

        model.setAudition(BuiltInPresets.bassBoost.id)
        model.clearAllOverrides()
        XCTAssertFalse(model.hasActiveOverride)
        XCTAssertNil(model.auditionPresetID)
    }

    func testForgettingADeviceRemovesItsRules() {
        let model = makeModel()
        model.setDevicePreset(BuiltInPresets.flat.id, forDeviceUID: "Gone")
        var rule = model.addAppRule(bundleID: "a.b", displayName: "A")
        rule.deviceUID = "Gone"
        model.updateRule(rule)
        model.addAppRule(bundleID: "c.d", displayName: "C")
        model.forgetDevice(uid: "Gone")
        XCTAssertEqual(model.rules.count, 1)
        XCTAssertEqual(model.rules.first?.app?.bundleID, "c.d")
    }

    func testDamagedFilesProduceAWarningInsteadOfACrash() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: directory.appendingPathComponent("rules.json"))
        let model = makeModel()
        XCTAssertTrue(model.rules.isEmpty)
        XCTAssertEqual(model.loadWarnings.count, 1)
        XCTAssertFalse(model.isFirstLaunch)
    }
}
