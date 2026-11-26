//
//  Preset.swift
//  TapEQ
//
//  A named EQ curve: a preamp gain plus an ordered list of bands.
//

import Foundation

struct Preset: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Gain applied before the bands, in dB.
    var preampDB: Double
    var bands: [Band]

    init(id: UUID = UUID(), name: String, preampDB: Double = 0, bands: [Band] = []) {
        self.id = id
        self.name = name
        self.preampDB = preampDB
        self.bands = bands
    }

    /// Built-in presets are read-only; duplicate one to edit it.
    var isBuiltIn: Bool { BuiltInPresets.ids.contains(id) }

    /// The same preset with every value forced into its legal range and no
    /// more than the maximum number of bands.
    func sanitized() -> Preset {
        var preset = self
        preset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset.name.isEmpty { preset.name = "Untitled" }
        preset.preampDB = preampDB.isFinite
            ? min(max(preampDB, EQLimits.preamp.lowerBound), EQLimits.preamp.upperBound)
            : 0
        preset.bands = bands.prefix(EQLimits.maxBands).map { $0.clamped() }
        return preset
    }

    /// How far the loudest point of the curve exceeds full scale after the
    /// preamp, in dB. Positive means the curve can clip.
    var headroomDeficit: Double {
        EQCurve.headroomDeficit(bands: bands, preampDB: preampDB)
    }

    /// A copy with fresh identifiers, safe to store next to the original.
    func duplicated(named newName: String) -> Preset {
        Preset(
            name: newName,
            preampDB: preampDB,
            bands: bands.map { band in
                var copy = band
                copy.id = UUID()
                return copy
            }
        )
    }
}

extension Preset: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, preampDB = "preamp", bands
    }

    /// Decoding is forgiving so a hand-edited or older file still loads:
    /// missing fields take defaults and out-of-range values are clamped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = Preset(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            preampDB: try container.decodeIfPresent(Double.self, forKey: .preampDB) ?? 0,
            bands: try container.decodeIfPresent([Band].self, forKey: .bands) ?? []
        )
        self = decoded.sanitized()
    }
}

/// The presets that ship with the app.
enum BuiltInPresets {
    static let flat = Preset(
        id: uuid(1),
        name: "Flat"
    )

    static let bassBoost = Preset(
        id: uuid(2),
        name: "Bass Boost",
        preampDB: -6,
        bands: [
            Band(id: uuid(0x21), type: .lowShelf, frequency: 110, gain: 6, q: 0.707),
        ]
    )

    static let bassCut = Preset(
        id: uuid(3),
        name: "Bass Cut",
        bands: [
            Band(id: uuid(0x31), type: .lowShelf, frequency: 140, gain: -6, q: 0.707),
        ]
    )

    static let vocalPresence = Preset(
        id: uuid(4),
        name: "Vocal Presence",
        preampDB: -4,
        bands: [
            Band(id: uuid(0x41), type: .peak, frequency: 250, gain: -2, q: 1),
            Band(id: uuid(0x42), type: .peak, frequency: 3_000, gain: 4, q: 1),
            Band(id: uuid(0x43), type: .highShelf, frequency: 10_000, gain: 1.5, q: 0.707),
        ]
    )

    static let trebleBoost = Preset(
        id: uuid(5),
        name: "Treble Boost",
        preampDB: -6,
        bands: [
            Band(id: uuid(0x51), type: .highShelf, frequency: 6_000, gain: 6, q: 0.707),
        ]
    )

    static let loudness = Preset(
        id: uuid(6),
        name: "Loudness",
        preampDB: -6,
        bands: [
            Band(id: uuid(0x61), type: .lowShelf, frequency: 90, gain: 6, q: 0.707),
            Band(id: uuid(0x62), type: .peak, frequency: 2_500, gain: -1.5, q: 0.8),
            Band(id: uuid(0x63), type: .highShelf, frequency: 9_000, gain: 4, q: 0.707),
        ]
    )

    static let all: [Preset] = [flat, bassBoost, bassCut, vocalPresence, trebleBoost, loudness]
    static let ids: Set<UUID> = Set(all.map(\.id))

    /// Built-ins keep fixed identifiers so rules that point at them survive
    /// reinstalls and updates.
    private static func uuid(_ number: UInt8) -> UUID {
        UUID(uuid: (0x7A, 0x9E, 0x51, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, number))
    }
}
