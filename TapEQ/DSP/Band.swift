//
//  Band.swift
//  TapEQ
//
//  The parameters of one EQ band, and the limits every band is clamped to.
//

import Foundation

/// The filter shape of a band.
enum BandType: String, Codable, CaseIterable, Identifiable, Sendable {
    case peak
    case lowShelf
    case highShelf
    case lowPass
    case highPass

    var id: String { rawValue }

    /// Low-pass and high-pass bands have no gain parameter.
    var usesGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: return true
        case .lowPass, .highPass: return false
        }
    }

    var displayName: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        case .lowPass: return "Low-pass"
        case .highPass: return "High-pass"
        }
    }
}

/// The ranges every preset parameter is clamped to.
enum EQLimits {
    static let maxBands = 12
    static let frequency: ClosedRange<Double> = 20...20_000
    static let gain: ClosedRange<Double> = -24...24
    static let q: ClosedRange<Double> = 0.1...10
    static let preamp: ClosedRange<Double> = -24...12
    /// Q of a second-order Butterworth section, the default for new bands.
    static let defaultQ = 0.707
}

/// One band of a preset.
struct Band: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var type: BandType
    /// Centre or corner frequency in Hz.
    var frequency: Double
    /// Gain in dB. Ignored by low-pass and high-pass bands.
    var gain: Double
    var q: Double
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        type: BandType = .peak,
        frequency: Double = 1_000,
        gain: Double = 0,
        q: Double = EQLimits.defaultQ,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.isEnabled = isEnabled
    }

    /// The same band with every parameter forced into its legal range.
    func clamped() -> Band {
        var band = self
        band.frequency = Self.clamp(frequency, to: EQLimits.frequency, fallback: 1_000)
        band.gain = Self.clamp(gain, to: EQLimits.gain, fallback: 0)
        band.q = Self.clamp(q, to: EQLimits.q, fallback: EQLimits.defaultQ)
        return band
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Codable

extension Band {
    // Decoding is forgiving so a hand-edited or older file still loads:
    // missing fields take defaults and out-of-range values are clamped.
    private enum CodingKeys: String, CodingKey {
        case id, type, frequency, gain, q, isEnabled = "enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            type: try container.decodeIfPresent(BandType.self, forKey: .type) ?? .peak,
            frequency: try container.decodeIfPresent(Double.self, forKey: .frequency) ?? 1_000,
            gain: try container.decodeIfPresent(Double.self, forKey: .gain) ?? 0,
            q: try container.decodeIfPresent(Double.self, forKey: .q) ?? EQLimits.defaultQ,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        )
        self = clamped()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(gain, forKey: .gain)
        try container.encode(q, forKey: .q)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}
