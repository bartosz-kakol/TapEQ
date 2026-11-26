//
//  AppModel.swift
//  TapEQ
//
//  The app's state: presets, rules, overrides and settings. The UI reads and
//  edits this; every change is saved and handed to the audio engine.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let engine: AudioEngine

    // MARK: State

    /// Presets the user created. Built-ins are not in this list.
    private(set) var userPresets: [Preset] = []
    private(set) var rules: [Rule] = []
    /// Every output device seen so far, connected or not.
    private(set) var knownDevices: [KnownDevice] = []
    private(set) var overrides = OverrideSet()
    /// The preset being auditioned from the preset editor, if any. While
    /// set, it acts as an override on the current output device.
    private(set) var auditionPresetID: UUID?

    var bypassAll = false {
        didSet {
            guard bypassAll != oldValue else { return }
            scheduleSave(.settings)
            pushConfiguration()
        }
    }

    var showDockIcon = false {
        didSet {
            guard showDockIcon != oldValue else { return }
            scheduleSave(.settings)
            applyActivationPolicy()
        }
    }

    /// Shows the name of the effective preset next to the menu bar glyph.
    var showsPresetInMenuBar = true {
        didSet {
            guard showsPresetInMenuBar != oldValue else { return }
            scheduleSave(.settings)
        }
    }

    /// Cancels the latency the system adds to tap audio on Bluetooth
    /// outputs. Opt-in: see the README for what can go wrong.
    var trimsBluetoothLatency = false {
        didSet {
            guard trimsBluetoothLatency != oldValue else { return }
            if trimsBluetoothLatency {
                // Turning it on again is a deliberate retry everywhere.
                latencyTrimDisabledDeviceUIDs.removeAll()
            }
            scheduleSave(.settings)
            pushConfiguration()
        }
    }

    /// Devices on which the latency trim went wrong and was switched off.
    private(set) var latencyTrimDisabledDeviceUIDs: [String] = []

    /// Problems found while loading, shown once in the main window.
    private(set) var loadWarnings: [String] = []
    /// True when no data existed yet: the first launch.
    private(set) var isFirstLaunch = false

    @ObservationIgnored private let store: PersistentStore
    @ObservationIgnored private var pendingSaves: Set<PersistentStore.File> = []
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var expiryTimer: Timer?

    // MARK: Derived

    /// Built-in presets followed by the user's own.
    var presets: [Preset] { BuiltInPresets.all + userPresets }

    func preset(_ id: UUID?) -> Preset? {
        guard let id else { return nil }
        return BuiltInPresets.all.first { $0.id == id } ?? userPresets.first { $0.id == id }
    }

    /// The name to show for a preset reference, including the two cases that
    /// are not presets: "None" and a preset that has been deleted.
    func presetName(_ id: UUID?) -> String {
        guard let id else { return "None" }
        return preset(id)?.name ?? "Deleted preset"
    }

    var hasActiveOverride: Bool {
        !overrides.isEmpty || auditionPresetID != nil
    }

    /// The text shown next to the menu bar glyph: the effective preset of
    /// the current output, or nil when the setting is off or nothing is
    /// equalized.
    var menuBarPresetText: String? {
        guard showsPresetInMenuBar else { return nil }
        return Self.menuBarPresetText(
            bypassAll: bypassAll,
            deviceResolution: engine.deviceResolution,
            playingApps: engine.playingApps,
            presetName: { self.preset($0)?.name }
        )
    }

    /// The output's own effective preset wins. Without one, the presets of
    /// the apps playing with an app-level preset: the name when there is
    /// one, a count when there are several. Nil when nothing is equalized.
    nonisolated static func menuBarPresetText(
        bypassAll: Bool,
        deviceResolution: Resolution,
        playingApps: [PlayingApp],
        presetName: (UUID) -> String?
    ) -> String? {
        guard !bypassAll else { return nil }
        if let id = deviceResolution.presetID, let name = presetName(id) {
            return truncatedForMenuBar(name)
        }
        var names: [String] = []
        for app in playingApps where !app.isOnOtherDevice {
            guard let id = app.resolution.presetID, let name = presetName(id), !names.contains(name) else { continue }
            names.append(name)
        }
        switch names.count {
        case 0: return nil
        case 1: return truncatedForMenuBar(names[0])
        default: return "\(names.count) presets"
        }
    }

    /// Menu bar space is shared with other apps; a long name is cut short.
    nonisolated static func truncatedForMenuBar(_ name: String, limit: Int = 24) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    var deviceRules: [Rule] { rules.filter { $0.kind == .device } }
    var appRules: [Rule] { rules.filter { $0.app != nil } }

    func deviceRule(forUID uid: String) -> Rule? {
        rules.first { $0.kind == .device && $0.deviceUID == uid }
    }

    func deviceName(forUID uid: String) -> String {
        engine.devices.first { $0.uid == uid }?.name
            ?? knownDevices.first { $0.uid == uid }?.name
            ?? uid
    }

    func isConnected(deviceUID uid: String) -> Bool {
        engine.devices.contains { $0.uid == uid }
    }

    // MARK: Lifecycle

    init(store: PersistentStore = .standard, engine: AudioEngine? = nil) {
        self.store = store
        self.engine = engine ?? AudioEngine()
        load()
    }

    /// Starts the audio engine. Kept separate from `init` so tests can build
    /// a model without touching the audio system.
    func start() {
        engine.onDevicesChanged = { [weak self] devices in
            self?.remember(devices)
        }
        engine.onDefaultOutputChanged = { [weak self] _ in
            guard let self else { return }
            if overrides.outputDeviceChanged() {
                rescheduleExpiry()
            }
            // The audition follows the output, and device rules now resolve
            // against the new device.
            pushConfiguration()
        }
        engine.onLatencyTrimFailed = { [weak self] device in
            guard let self, !latencyTrimDisabledDeviceUIDs.contains(device.uid) else { return }
            latencyTrimDisabledDeviceUIDs.append(device.uid)
            scheduleSave(.settings)
            pushConfiguration()
        }
        pushConfiguration()
        applyActivationPolicy()
        engine.start()
    }

    /// Writes anything not yet saved and shuts the engine down.
    func shutDown() {
        flush()
        engine.stop()
    }

    // MARK: Loading and saving

    private func load() {
        let presetsResult = store.load(PresetsFile.self, from: .presets)
        let rulesResult = store.load(RulesFile.self, from: .rules)
        let settingsResult = store.load(SettingsFile.self, from: .settings)

        isFirstLaunch = presetsResult.outcome == .missing
            && rulesResult.outcome == .missing
            && settingsResult.outcome == .missing

        // A user preset must not shadow a built-in or another user preset.
        var seen = BuiltInPresets.ids
        userPresets = (presetsResult.value?.presets ?? []).filter { seen.insert($0.id).inserted }
        rules = (rulesResult.value?.rules ?? []).filter { $0.kind != nil }
        knownDevices = rulesResult.value?.knownDevices ?? []
        if let settings = settingsResult.value {
            bypassAll = settings.bypassAll
            showDockIcon = settings.showDockIcon
            showsPresetInMenuBar = settings.showsPresetInMenuBar
            trimsBluetoothLatency = settings.trimsBluetoothLatency
            latencyTrimDisabledDeviceUIDs = settings.latencyTrimDisabledDeviceUIDs
        }
        // The property observers above queue a save; nothing changed yet.
        pendingSaves.removeAll()

        let outcomes: [(String, PersistentStore.LoadOutcome)] = [
            ("presets", presetsResult.outcome), ("rules", rulesResult.outcome), ("settings", settingsResult.outcome),
        ]
        for (name, outcome) in outcomes {
            switch outcome {
            case .recoveredFromBackup:
                loadWarnings.append("Your \(name) file was damaged, so the previous version was restored from its backup.")
            case .unreadable:
                loadWarnings.append("Your \(name) file could not be read and there was no usable backup. TapEQ started with empty \(name); the damaged file is left in place until you change something.")
            case .loaded, .missing:
                break
            }
        }
    }

    func dismissLoadWarnings() {
        loadWarnings.removeAll()
    }

    private func scheduleSave(_ file: PersistentStore.File) {
        pendingSaves.insert(file)
        guard !saveScheduled else { return }
        saveScheduled = true
        // Dragging a band handle changes the preset many times a second;
        // one write once things settle is enough.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Writes every file with unsaved changes now.
    func flush() {
        saveScheduled = false
        let files = pendingSaves
        pendingSaves.removeAll()
        for file in files {
            do {
                switch file {
                case .presets: try store.save(PresetsFile(presets: userPresets), to: .presets)
                case .rules: try store.save(RulesFile(rules: rules, knownDevices: knownDevices), to: .rules)
                case .settings:
                    try store.save(SettingsFile(
                        bypassAll: bypassAll,
                        showDockIcon: showDockIcon,
                        showsPresetInMenuBar: showsPresetInMenuBar,
                        trimsBluetoothLatency: trimsBluetoothLatency,
                        latencyTrimDisabledDeviceUIDs: latencyTrimDisabledDeviceUIDs
                    ), to: .settings)
                }
            } catch {
                loadWarnings.append("Could not save \(file.rawValue): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Engine

    /// The overrides in force, with the audition in front of them.
    private var activeOverrides: [Override] {
        var active = overrides.overrides
        if let auditionPresetID, let device = engine.currentDevice {
            // Ahead of any ordinary device override, so the audition wins.
            active.insert(Override(target: .device(uid: device.uid), presetID: auditionPresetID, lifetime: .untilCleared), at: 0)
        }
        return active
    }

    private func resolutionContext(bypassAll: Bool, overrides: [Override]) -> ResolutionContext {
        ResolutionContext(
            bypassAll: bypassAll,
            rules: rules,
            overrides: overrides,
            knownPresetIDs: Set(presets.map(\.id))
        )
    }

    /// What the rules give the current output once its override is
    /// cleared, as if EQ were on: what "Follow Rules" would bring back.
    func ruleResolutionForCurrentDevice() -> Resolution {
        let others = activeOverrides.filter { if case .device = $0.target { return false } else { return true } }
        return Resolver.resolveDevice(
            deviceUID: engine.currentDevice?.uid,
            in: resolutionContext(bypassAll: false, overrides: others)
        )
    }

    /// What the rules give a playing app once its override is cleared, as
    /// if EQ were on. The output's own override still counts.
    func ruleResolution(for app: PlayingApp) -> Resolution {
        let others = activeOverrides.filter { if case .app = $0.target { return false } else { return true } }
        return Resolver.resolve(
            processBundleIDs: app.matchIDs.isEmpty ? [app.id] : app.matchIDs,
            deviceUID: engine.currentDevice?.uid,
            in: resolutionContext(bypassAll: false, overrides: others)
        )
    }

    private func pushConfiguration() {
        let all = presets
        engine.apply(EngineConfiguration(
            context: resolutionContext(bypassAll: bypassAll, overrides: activeOverrides),
            presets: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }),
            trimsBluetoothLatency: trimsBluetoothLatency,
            latencyTrimDisabledDeviceUIDs: Set(latencyTrimDisabledDeviceUIDs)
        ))
    }

    private func applyActivationPolicy() {
        // Unit tests host the model inside the app; leave the Dock alone.
        guard NSApp != nil, !AppEnvironment.isRunningTests else { return }
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    // MARK: Presets

    private func uniqueName(_ base: String) -> String {
        let taken = Set(presets.map(\.name))
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    @discardableResult
    func addPreset() -> Preset {
        let preset = Preset(name: uniqueName("New Preset"), bands: [
            Band(type: .lowShelf, frequency: 100, gain: 0),
            Band(type: .peak, frequency: 1_000, gain: 0, q: 1),
            Band(type: .highShelf, frequency: 8_000, gain: 0),
        ])
        userPresets.append(preset)
        presetsChanged()
        return preset
    }

    @discardableResult
    func duplicatePreset(_ id: UUID) -> Preset? {
        guard let original = preset(id) else { return nil }
        let copy = original.duplicated(named: uniqueName("\(original.name) copy"))
        userPresets.append(copy)
        presetsChanged()
        return copy
    }

    /// Replaces a user preset with an edited version. Built-ins are
    /// read-only and are ignored.
    func updatePreset(_ edited: Preset) {
        guard !edited.isBuiltIn, let index = userPresets.firstIndex(where: { $0.id == edited.id }) else { return }
        var sanitized = edited
        sanitized.preampDB = min(max(edited.preampDB, EQLimits.preamp.lowerBound), EQLimits.preamp.upperBound)
        sanitized.bands = edited.bands.prefix(EQLimits.maxBands).map { $0.clamped() }
        guard userPresets[index] != sanitized else { return }
        userPresets[index] = sanitized
        presetsChanged()
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != userPresets[index].name else { return }
        userPresets[index].name = trimmed
        presetsChanged()
    }

    /// Deletes a user preset. Rules that pointed at it stay, are shown as
    /// pointing at a deleted preset, and are skipped during resolution.
    func deletePreset(_ id: UUID) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets.remove(at: index)
        if auditionPresetID == id { auditionPresetID = nil }
        presetsChanged()
    }

    /// How many rules refer to a preset, for the delete confirmation.
    func ruleCount(usingPreset id: UUID) -> Int {
        rules.filter { $0.presetID == id }.count
    }

    private func presetsChanged() {
        scheduleSave(.presets)
        pushConfiguration()
    }

    /// Imports a preset file as a new user preset.
    @discardableResult
    func importPreset(from url: URL) throws -> Preset {
        var preset = try PersistentStore.importPreset(from: Data(contentsOf: url))
        // Always a new preset: importing the same file twice, or a file
        // exported from a built-in, must not replace anything.
        preset = preset.duplicated(named: uniqueName(preset.name))
        userPresets.append(preset)
        presetsChanged()
        return preset
    }

    func exportPreset(_ id: UUID, to url: URL) throws {
        guard let preset = preset(id) else { return }
        try PersistentStore.exportData(for: preset).write(to: url, options: .atomic)
    }

    // MARK: Rules

    /// Sets the device rule for an output device. Choosing "None" removes
    /// the rule: for a device, no rule and a rule of "None" mean the same.
    func setDevicePreset(_ presetID: UUID?, forDeviceUID uid: String) {
        rules.removeAll { $0.kind == .device && $0.deviceUID == uid }
        if let presetID {
            rules.append(.device(uid: uid, presetID: presetID))
        }
        rulesChanged()
    }

    /// Adds an app rule, initially "None" on any device, and returns it.
    @discardableResult
    func addAppRule(bundleID: String, displayName: String) -> Rule {
        let target = AppTarget(
            bundleID: bundleID,
            displayName: displayName,
            extraBundleIDs: AppIdentityResolver.suggestedExtraBundleIDs(forApp: bundleID)
        )
        let rule = Rule.app(target, presetID: nil)
        rules.append(rule)
        rulesChanged()
        return rule
    }

    func updateRule(_ rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }), rules[index] != rule else { return }
        rules[index] = rule
        rulesChanged()
    }

    func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        rulesChanged()
    }

    /// Whether an earlier rule has the same app and device, in which case
    /// this one can never win.
    func isShadowed(_ rule: Rule) -> Bool {
        guard let app = rule.app, let index = rules.firstIndex(where: { $0.id == rule.id }) else { return false }
        return rules[..<index].contains {
            $0.app?.bundleID.lowercased() == app.bundleID.lowercased() && $0.deviceUID == rule.deviceUID
        }
    }

    /// Forgets a disconnected device and every rule tied to it.
    func forgetDevice(uid: String) {
        knownDevices.removeAll { $0.uid == uid }
        rules.removeAll { $0.deviceUID == uid }
        overrides.clear(.device(uid: uid))
        rulesChanged()
    }

    private func rulesChanged() {
        scheduleSave(.rules)
        pushConfiguration()
    }

    private func remember(_ devices: [OutputDevice]) {
        var changed = false
        for device in devices {
            if let index = knownDevices.firstIndex(where: { $0.uid == device.uid }) {
                if knownDevices[index].name != device.name {
                    knownDevices[index].name = device.name
                    changed = true
                }
            } else {
                knownDevices.append(KnownDevice(uid: device.uid, name: device.name))
                changed = true
            }
        }
        if changed { scheduleSave(.rules) }
    }

    // MARK: Overrides

    func override(for target: Override.Target) -> Override? {
        overrides[target]
    }

    func setOverride(_ target: Override.Target, presetID: UUID?, lifetime: OverrideLifetime) {
        overrides.set(Override(target: target, presetID: presetID, lifetime: lifetime))
        rescheduleExpiry()
        pushConfiguration()
    }

    func clearOverride(_ target: Override.Target) {
        overrides.clear(target)
        rescheduleExpiry()
        pushConfiguration()
    }

    func clearAllOverrides() {
        overrides.clearAll()
        auditionPresetID = nil
        rescheduleExpiry()
        pushConfiguration()
    }

    /// Starts or stops auditioning a preset on the current output.
    func setAudition(_ presetID: UUID?) {
        guard auditionPresetID != presetID else { return }
        auditionPresetID = presetID
        pushConfiguration()
    }

    private func rescheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let next = overrides.nextExpiry else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.overrides.removeExpired() {
                    self.pushConfiguration()
                }
                self.rescheduleExpiry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }
}

/// Facts about how the process was started.
enum AppEnvironment {
    /// True when the app is only running as the host of its unit tests, in
    /// which case it must not touch the audio system or the user's data.
    static let isRunningTests: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
