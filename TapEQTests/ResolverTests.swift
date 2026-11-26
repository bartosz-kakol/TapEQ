//
//  ResolverTests.swift
//  TapEQTests
//

import XCTest
@testable import TapEQ

final class ResolverTests: XCTestCase {
    private let speakers = "BuiltInSpeakerDevice"
    private let airPods = "AA-BB-CC:output"

    private let appOverridePreset = UUID()
    private let appOnDevicePreset = UUID()
    private let appPreset = UUID()
    private let deviceOverridePreset = UUID()
    private let devicePreset = UUID()

    private let spotify = AppTarget(bundleID: "com.spotify.client", displayName: "Spotify")

    /// A context in which every step of the order has a match for Spotify on
    /// the speakers.
    private func fullContext() -> ResolutionContext {
        ResolutionContext(
            bypassAll: false,
            rules: [
                .device(uid: speakers, presetID: devicePreset),
                .app(spotify, presetID: appPreset),
                .app(spotify, onDevice: speakers, presetID: appOnDevicePreset),
            ],
            overrides: [
                Override(target: .device(uid: speakers), presetID: deviceOverridePreset, lifetime: .untilCleared),
                Override(target: .app(bundleID: "com.spotify.client"), presetID: appOverridePreset, lifetime: .untilCleared),
            ]
        )
    }

    private func resolveSpotify(on device: String?, in context: ResolutionContext) -> Resolution {
        Resolver.resolve(processBundleIDs: ["com.spotify.client"], deviceUID: device, in: context)
    }

    // MARK: - The order, one step at a time

    func testStep1BypassBeatsEverything() {
        var context = fullContext()
        context.bypassAll = true
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .bypass))
        XCTAssertEqual(Resolver.resolveDevice(deviceUID: speakers, in: context), Resolution(presetID: nil, source: .bypass))
    }

    func testStep2AppOverrideBeatsAllRules() {
        XCTAssertEqual(
            resolveSpotify(on: speakers, in: fullContext()),
            Resolution(presetID: appOverridePreset, source: .appOverride)
        )
    }

    func testStep3AppOnDeviceRuleBeatsAppRule() {
        var context = fullContext()
        context.overrides.removeAll { $0.target == .app(bundleID: "com.spotify.client") }
        XCTAssertEqual(
            resolveSpotify(on: speakers, in: context),
            Resolution(presetID: appOnDevicePreset, source: .appOnDeviceRule)
        )
    }

    func testStep3OnlyAppliesOnItsDevice() {
        var context = fullContext()
        context.overrides.removeAll()
        XCTAssertEqual(resolveSpotify(on: airPods, in: context), Resolution(presetID: appPreset, source: .appRule))
        XCTAssertEqual(resolveSpotify(on: nil, in: context), Resolution(presetID: appPreset, source: .appRule))
    }

    func testStep4AppRuleBeatsDeviceOverrideAndDeviceRule() {
        var context = fullContext()
        context.overrides.removeAll { $0.target == .app(bundleID: "com.spotify.client") }
        context.rules.removeAll { $0.kind == .appOnDevice }
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: appPreset, source: .appRule))
    }

    func testStep5DeviceOverrideBeatsDeviceRule() {
        var context = fullContext()
        context.rules.removeAll { $0.app != nil }
        context.overrides.removeAll { $0.target == .app(bundleID: "com.spotify.client") }
        let expected = Resolution(presetID: deviceOverridePreset, source: .deviceOverride)
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), expected)
        XCTAssertEqual(Resolver.resolveDevice(deviceUID: speakers, in: context), expected)
    }

    func testStep6DeviceRule() {
        var context = fullContext()
        context.rules.removeAll { $0.app != nil }
        context.overrides.removeAll()
        let expected = Resolution(presetID: devicePreset, source: .deviceRule)
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), expected)
        XCTAssertEqual(Resolver.resolveDevice(deviceUID: speakers, in: context), expected)
    }

    func testStep7NothingMatches() {
        let empty = ResolutionContext()
        XCTAssertEqual(resolveSpotify(on: speakers, in: empty), .unmatched)
        XCTAssertEqual(Resolver.resolveDevice(deviceUID: speakers, in: empty), .unmatched)

        var context = fullContext()
        context.overrides.removeAll()
        context.rules.removeAll { $0.app != nil }
        // The only rule left is for the speakers.
        XCTAssertEqual(resolveSpotify(on: airPods, in: context), .unmatched)
        XCTAssertEqual(resolveSpotify(on: nil, in: context), .unmatched)
    }

    func testOtherAppsFallThroughToTheDevice() {
        let resolution = Resolver.resolve(processBundleIDs: ["com.apple.Safari"], deviceUID: speakers, in: fullContext())
        XCTAssertEqual(resolution, Resolution(presetID: deviceOverridePreset, source: .deviceOverride))
    }

    func testDeviceOverrideForAnotherDeviceDoesNotApply() {
        var context = ResolutionContext()
        context.overrides = [Override(target: .device(uid: airPods), presetID: deviceOverridePreset, lifetime: .untilCleared)]
        context.rules = [.device(uid: speakers, presetID: devicePreset)]
        XCTAssertEqual(
            Resolver.resolveDevice(deviceUID: speakers, in: context),
            Resolution(presetID: devicePreset, source: .deviceRule)
        )
    }

    // MARK: - "None" stops resolution

    func testNoneAtEachStepStopsResolutionWithNoEQ() {
        // App override of None beats an app rule with a preset.
        var context = fullContext()
        context.overrides = [Override(target: .app(bundleID: "com.spotify.client"), presetID: nil, lifetime: .untilCleared)]
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .appOverride))

        // App-on-device rule of None beats the any-device app rule.
        context = fullContext()
        context.overrides.removeAll()
        context.rules = [
            .app(spotify, onDevice: speakers, presetID: nil),
            .app(spotify, presetID: appPreset),
            .device(uid: speakers, presetID: devicePreset),
        ]
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .appOnDeviceRule))

        // App rule of None beats the device rule.
        context.rules = [.app(spotify, presetID: nil), .device(uid: speakers, presetID: devicePreset)]
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .appRule))

        // Device override of None beats the device rule.
        context.rules = [.device(uid: speakers, presetID: devicePreset)]
        context.overrides = [Override(target: .device(uid: speakers), presetID: nil, lifetime: .untilCleared)]
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .deviceOverride))

        // Device rule of None is a match, not a miss.
        context.overrides = []
        context.rules = [.device(uid: speakers, presetID: nil)]
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .deviceRule))
    }

    // MARK: - Matching apps

    func testBundleIDPrefixMatchesHelpersAtADotBoundary() {
        XCTAssertTrue(Resolver.matches(ruleBundleID: "com.google.Chrome", processBundleID: "com.google.Chrome"))
        XCTAssertTrue(Resolver.matches(ruleBundleID: "com.google.Chrome", processBundleID: "com.google.Chrome.helper"))
        XCTAssertTrue(Resolver.matches(ruleBundleID: "com.google.Chrome", processBundleID: "com.google.Chrome.helper.renderer"))
        XCTAssertTrue(Resolver.matches(ruleBundleID: "com.google.chrome", processBundleID: "com.google.Chrome.helper"))
        XCTAssertFalse(Resolver.matches(ruleBundleID: "com.google.Chrome", processBundleID: "com.google.ChromeRemoteDesktop"))
        XCTAssertFalse(Resolver.matches(ruleBundleID: "com.google.Chrome.helper", processBundleID: "com.google.Chrome"))
        XCTAssertFalse(Resolver.matches(ruleBundleID: "", processBundleID: "com.google.Chrome"))
        XCTAssertFalse(Resolver.matches(ruleBundleID: "com.google.Chrome", processBundleID: ""))
    }

    func testHelperProcessMatchesItsAppRule() {
        let chrome = AppTarget(bundleID: "com.google.Chrome", displayName: "Chrome")
        let context = ResolutionContext(rules: [.app(chrome, presetID: appPreset)])
        let resolution = Resolver.resolve(processBundleIDs: ["com.google.Chrome.helper"], deviceUID: speakers, in: context)
        XCTAssertEqual(resolution, Resolution(presetID: appPreset, source: .appRule))
    }

    func testExtraBundleIDsMatch() {
        let safari = AppTarget(bundleID: "com.apple.Safari", displayName: "Safari", extraBundleIDs: [" com.apple.WebKit.GPU ", ""])
        let context = ResolutionContext(rules: [.app(safari, presetID: appPreset)])
        XCTAssertEqual(
            Resolver.resolve(processBundleIDs: ["com.apple.WebKit.GPU"], deviceUID: nil, in: context),
            Resolution(presetID: appPreset, source: .appRule)
        )
        XCTAssertEqual(
            Resolver.resolve(processBundleIDs: ["com.apple.WebKit.Networking"], deviceUID: nil, in: context),
            .unmatched
        )
    }

    func testAnyOfTheProcessIdentifiersCanMatch() {
        // A helper with an unrelated identifier, known to belong to Slack.
        let slack = AppTarget(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")
        let context = ResolutionContext(rules: [.app(slack, presetID: appPreset)])
        let resolution = Resolver.resolve(
            processBundleIDs: ["com.github.Electron.helper", "com.tinyspeck.slackmacgap"],
            deviceUID: nil,
            in: context
        )
        XCTAssertEqual(resolution, Resolution(presetID: appPreset, source: .appRule))
    }

    func testMostSpecificRuleWinsRegardlessOfOrder() {
        let chrome = AppTarget(bundleID: "com.google.Chrome", displayName: "Chrome")
        let canary = AppTarget(bundleID: "com.google.Chrome.canary", displayName: "Chrome Canary")
        let canaryPreset = UUID()
        for rules in [
            [Rule.app(chrome, presetID: appPreset), .app(canary, presetID: canaryPreset)],
            [Rule.app(canary, presetID: canaryPreset), .app(chrome, presetID: appPreset)],
        ] {
            let context = ResolutionContext(rules: rules)
            XCTAssertEqual(
                Resolver.resolve(processBundleIDs: ["com.google.Chrome.canary.helper"], deviceUID: nil, in: context).presetID,
                canaryPreset
            )
            XCTAssertEqual(
                Resolver.resolve(processBundleIDs: ["com.google.Chrome.helper"], deviceUID: nil, in: context).presetID,
                appPreset
            )
        }
    }

    func testFirstOfTwoEquallySpecificRulesWins() {
        let other = UUID()
        let context = ResolutionContext(rules: [.app(spotify, presetID: appPreset), .app(spotify, presetID: other)])
        XCTAssertEqual(resolveSpotify(on: nil, in: context).presetID, appPreset)
    }

    func testAppOverrideMatchesHelpersToo() {
        let context = ResolutionContext(overrides: [
            Override(target: .app(bundleID: "com.google.Chrome"), presetID: appOverridePreset, lifetime: .oneHour),
        ])
        XCTAssertEqual(
            Resolver.resolve(processBundleIDs: ["com.google.Chrome.helper"], deviceUID: nil, in: context),
            Resolution(presetID: appOverridePreset, source: .appOverride)
        )
    }

    // MARK: - Deleted presets

    func testRulesAndOverridesPointingAtMissingPresetsAreSkipped() {
        var context = fullContext()
        // Only the device rule's preset still exists.
        context.knownPresetIDs = [devicePreset]
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: devicePreset, source: .deviceRule))

        // "None" never dangles.
        context.rules.insert(.app(spotify, presetID: nil), at: 0)
        XCTAssertEqual(resolveSpotify(on: speakers, in: context), Resolution(presetID: nil, source: .appRule))
    }

    // MARK: - Overrides

    func testOverrideLifetimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var set = OverrideSet()
        set.set(Override(target: .device(uid: speakers), presetID: devicePreset, lifetime: .untilDeviceChange, now: now))
        set.set(Override(target: .app(bundleID: "a"), presetID: appPreset, lifetime: .oneHour, now: now))
        set.set(Override(target: .app(bundleID: "b"), presetID: nil, lifetime: .untilCleared, now: now))
        XCTAssertEqual(set.overrides.count, 3)
        XCTAssertEqual(set.nextExpiry, now.addingTimeInterval(3_600))

        XCTAssertFalse(set.removeExpired(at: now.addingTimeInterval(3_599)))
        XCTAssertTrue(set.removeExpired(at: now.addingTimeInterval(3_600)))
        XCTAssertNil(set[.app(bundleID: "a")])
        XCTAssertNil(set.nextExpiry)

        XCTAssertTrue(set.outputDeviceChanged())
        XCTAssertNil(set[.device(uid: speakers)])
        XCTAssertFalse(set.outputDeviceChanged())

        XCTAssertNotNil(set[.app(bundleID: "b")])
        set.clearAll()
        XCTAssertTrue(set.isEmpty)
    }

    func testSettingAnOverrideReplacesTheOneForTheSameTarget() {
        var set = OverrideSet()
        set.set(Override(target: .device(uid: speakers), presetID: devicePreset, lifetime: .untilCleared))
        set.set(Override(target: .device(uid: speakers), presetID: nil, lifetime: .oneHour))
        XCTAssertEqual(set.overrides.count, 1)
        XCTAssertNil(set[.device(uid: speakers)]?.presetID)
        XCTAssertEqual(set[.device(uid: speakers)]?.lifetime, .oneHour)
    }

    func testAppOverrideCannotBeTiedToTheDevice() {
        let override = Override(target: .app(bundleID: "a"), presetID: nil, lifetime: .untilDeviceChange)
        XCTAssertEqual(override.lifetime, .untilCleared)
        XCTAssertEqual(OverrideLifetime.options(for: .app(bundleID: "a")), [.untilCleared, .oneHour])
        XCTAssertEqual(OverrideLifetime.options(for: .device(uid: "d")), [.untilCleared, .untilDeviceChange, .oneHour])
    }
}
