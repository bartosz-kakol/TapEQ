//
//  Override.swift
//  TapEQ
//
//  Temporary replacements for rules, set from the menu bar. Overrides live in
//  memory only and are gone after a restart.
//

import Foundation

/// How long an override stays in force.
enum OverrideLifetime: String, CaseIterable, Identifiable, Sendable {
    case untilCleared
    /// Device overrides only: ends when the default output device changes.
    case untilDeviceChange
    case oneHour

    var id: String { rawValue }

    static let hour: TimeInterval = 3_600

    var displayName: String {
        switch self {
        case .untilCleared: return "Until cleared"
        case .untilDeviceChange: return "Until output changes"
        case .oneHour: return "For 1 hour"
        }
    }

    /// Lifetimes that make sense for the given kind of target.
    static func options(for target: Override.Target) -> [OverrideLifetime] {
        switch target {
        case .app: return [.untilCleared, .oneHour]
        case .device: return [.untilCleared, .untilDeviceChange, .oneHour]
        }
    }
}

struct Override: Equatable, Identifiable, Sendable {
    enum Target: Hashable, Sendable {
        /// An app, by the identifier it is listed under in "Playing now".
        case app(bundleID: String)
        /// An output device, by UID.
        case device(uid: String)
    }

    let target: Target
    /// The preset to apply instead, or nil for "None".
    let presetID: UUID?
    let lifetime: OverrideLifetime
    /// When the override ends, for lifetimes that end on their own.
    let expiresAt: Date?

    var id: Target { target }

    init(target: Target, presetID: UUID?, lifetime: OverrideLifetime, now: Date = Date()) {
        self.target = target
        self.presetID = presetID
        // An app override cannot be tied to the output device.
        if case .app = target, lifetime == .untilDeviceChange {
            self.lifetime = .untilCleared
        } else {
            self.lifetime = lifetime
        }
        expiresAt = self.lifetime == .oneHour ? now.addingTimeInterval(OverrideLifetime.hour) : nil
    }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}

/// The set of overrides currently in force: at most one per target.
struct OverrideSet: Equatable, Sendable {
    private(set) var overrides: [Override] = []

    var isEmpty: Bool { overrides.isEmpty }

    subscript(target: Override.Target) -> Override? {
        overrides.first { $0.target == target }
    }

    /// Adds an override, replacing any existing one for the same target.
    mutating func set(_ override: Override) {
        overrides.removeAll { $0.target == override.target }
        overrides.append(override)
    }

    mutating func clear(_ target: Override.Target) {
        overrides.removeAll { $0.target == target }
    }

    mutating func clearAll() {
        overrides.removeAll()
    }

    /// Drops overrides whose time is up. Returns true if any were dropped.
    @discardableResult
    mutating func removeExpired(at date: Date = Date()) -> Bool {
        let before = overrides.count
        overrides.removeAll { $0.isExpired(at: date) }
        return overrides.count != before
    }

    /// Drops device overrides that end when the output device changes.
    /// Returns true if any were dropped.
    @discardableResult
    mutating func outputDeviceChanged() -> Bool {
        let before = overrides.count
        overrides.removeAll { $0.lifetime == .untilDeviceChange }
        return overrides.count != before
    }

    /// The soonest moment an override expires on its own, if any does.
    var nextExpiry: Date? {
        overrides.compactMap(\.expiresAt).min()
    }
}
