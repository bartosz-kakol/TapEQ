//
//  Resolver.swift
//  TapEQ
//
//  Decides which preset applies to a process. This is the one place the
//  resolution order lives, and it is pure: no state, no side effects.
//

import Foundation

/// Where an effective preset came from.
enum PresetSource: Equatable, Sendable {
    /// "Bypass all EQ" is on.
    case bypass
    case appOverride
    /// A rule for the app on the current output device.
    case appOnDeviceRule
    /// A rule for the app on any device.
    case appRule
    case deviceOverride
    case deviceRule
    /// Nothing matched.
    case none

    /// Whether the app itself decided the outcome, as opposed to the output
    /// device. App-level processes get their own tap, or none at all.
    var isAppLevel: Bool {
        switch self {
        case .appOverride, .appOnDeviceRule, .appRule: return true
        case .bypass, .deviceOverride, .deviceRule, .none: return false
        }
    }

    var isOverride: Bool {
        self == .appOverride || self == .deviceOverride
    }

    var displayName: String {
        switch self {
        case .bypass: return "Bypassed"
        case .appOverride, .deviceOverride: return "Override"
        case .appOnDeviceRule, .appRule: return "App rule"
        case .deviceRule: return "Device rule"
        case .none: return "None"
        }
    }
}

/// The effective preset for one audio stream.
struct Resolution: Equatable, Sendable {
    /// The preset to apply, or nil for no EQ.
    let presetID: UUID?
    let source: PresetSource

    static let unmatched = Resolution(presetID: nil, source: .none)
    static let bypassed = Resolution(presetID: nil, source: .bypass)
}

/// Everything resolution depends on besides the process and the device.
struct ResolutionContext: Equatable, Sendable {
    var bypassAll = false
    var rules: [Rule] = []
    var overrides: [Override] = []
    /// Presets that exist. A rule or override that points at a preset
    /// outside this set (one that was deleted) is skipped as if it were not
    /// there. Nil skips this check.
    var knownPresetIDs: Set<UUID>?
}

enum Resolver {
    /// The effective preset for a process playing on the current default
    /// output device. The first step that matches wins:
    ///
    /// 1. "Bypass all EQ" is on → None.
    /// 2. Temporary override for the process's app.
    /// 3. Rule for the app on this device.
    /// 4. Rule for the app on any device.
    /// 5. Temporary override for the device.
    /// 6. Rule for the device.
    /// 7. None.
    ///
    /// A match whose preset is "None" still wins: it means "never equalize
    /// this", and resolution stops there.
    ///
    /// - Parameters:
    ///   - processBundleIDs: Identifiers that stand for the process: its own
    ///     bundle ID and, for a helper, the bundle ID of the app it belongs to.
    ///   - deviceUID: UID of the current default output device, if there is one.
    static func resolve(
        processBundleIDs: [String],
        deviceUID: String?,
        in context: ResolutionContext
    ) -> Resolution {
        // 1.
        if context.bypassAll { return .bypassed }

        // 2.
        let appOverrides: [(id: String, presetID: UUID?)] = context.overrides.compactMap { override in
            guard case .app(let bundleID) = override.target, isUsable(override.presetID, in: context) else { return nil }
            return (bundleID, override.presetID)
        }
        if let match = mostSpecific(appOverrides.map { ([$0.id], $0.presetID) }, for: processBundleIDs) {
            return Resolution(presetID: match, source: .appOverride)
        }

        // 3.
        if let deviceUID {
            let candidates = appRules(in: context) { $0.deviceUID == deviceUID }
            if let match = mostSpecific(candidates, for: processBundleIDs) {
                return Resolution(presetID: match, source: .appOnDeviceRule)
            }
        }

        // 4.
        let anyDevice = appRules(in: context) { $0.deviceUID == nil }
        if let match = mostSpecific(anyDevice, for: processBundleIDs) {
            return Resolution(presetID: match, source: .appRule)
        }

        // 5–7.
        return resolveDevice(deviceUID: deviceUID, in: context)
    }

    /// The device-level outcome: steps 1 and 5–7 of the order above. This is
    /// what applies to every process no app-level step claims.
    static func resolveDevice(deviceUID: String?, in context: ResolutionContext) -> Resolution {
        if context.bypassAll { return .bypassed }
        guard let deviceUID else { return .unmatched }

        // 5.
        for override in context.overrides {
            if case .device(let uid) = override.target, uid == deviceUID, isUsable(override.presetID, in: context) {
                return Resolution(presetID: override.presetID, source: .deviceOverride)
            }
        }
        // 6.
        for rule in context.rules where rule.kind == .device && rule.deviceUID == deviceUID {
            if isUsable(rule.presetID, in: context) {
                return Resolution(presetID: rule.presetID, source: .deviceRule)
            }
        }
        // 7.
        return .unmatched
    }

    /// Whether a rule written for `ruleBundleID` covers a process identified
    /// as `processBundleID`: the same identifier, or one that extends it at a
    /// dot. `com.google.Chrome` covers `com.google.Chrome.helper` but not
    /// `com.google.ChromeRemoteDesktop`.
    static func matches(ruleBundleID: String, processBundleID: String) -> Bool {
        guard !ruleBundleID.isEmpty, !processBundleID.isEmpty else { return false }
        let rule = ruleBundleID.lowercased()
        let process = processBundleID.lowercased()
        return process == rule || process.hasPrefix(rule + ".")
    }

    // MARK: Helpers

    private static func isUsable(_ presetID: UUID?, in context: ResolutionContext) -> Bool {
        guard let presetID, let known = context.knownPresetIDs else { return true }
        return known.contains(presetID)
    }

    private static func appRules(
        in context: ResolutionContext,
        where include: (Rule) -> Bool
    ) -> [(ids: [String], presetID: UUID?)] {
        context.rules.compactMap { rule in
            guard let app = rule.app, include(rule), isUsable(rule.presetID, in: context) else { return nil }
            return (app.allBundleIDs, rule.presetID)
        }
    }

    /// Among the candidates that match the process, the one whose matching
    /// identifier is longest, so a rule for `com.google.Chrome.canary` beats
    /// one for `com.google.Chrome`. Ties go to the earlier candidate.
    ///
    /// The result is doubly optional: nil means nothing matched, while
    /// `.some(nil)` means a match whose preset is "None".
    private static func mostSpecific(
        _ candidates: [(ids: [String], presetID: UUID?)],
        for processBundleIDs: [String]
    ) -> UUID?? {
        var best: (length: Int, presetID: UUID?)?
        for candidate in candidates {
            for ruleID in candidate.ids {
                guard processBundleIDs.contains(where: { matches(ruleBundleID: ruleID, processBundleID: $0) }) else {
                    continue
                }
                if best == nil || ruleID.count > best!.length {
                    best = (ruleID.count, candidate.presetID)
                }
            }
        }
        guard let best else { return nil }
        return .some(best.presetID)
    }
}
