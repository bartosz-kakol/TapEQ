//
//  EQCurve.swift
//  TapEQ
//
//  The combined magnitude response of a set of bands, for drawing the curve
//  and for the headroom warning.
//

import Foundation

enum EQCurve {
    /// The sample rate used to draw curves when no device rate is known.
    static let displaySampleRate = 48_000.0

    /// Combined magnitude response in dB at each of `frequencies`.
    ///
    /// - Parameters:
    ///   - bands: The bands of the preset. Disabled bands contribute nothing.
    ///   - preampDB: Added to every point. Pass 0 to get the bands alone.
    ///   - frequencies: Frequencies in Hz, in any order.
    ///   - sampleRate: The rate the filters are designed for.
    static func response(
        bands: [Band],
        preampDB: Double = 0,
        at frequencies: [Double],
        sampleRate: Double = displaySampleRate
    ) -> [Double] {
        let coefficients = bands
            .prefix(EQLimits.maxBands)
            .map { BiquadCoefficients.design($0, sampleRate: sampleRate) }
            .filter { !$0.isIdentity }
        return frequencies.map { frequency in
            var total = preampDB
            // Above Nyquist the response is not defined; hold the last value.
            let evaluated = min(frequency, sampleRate * 0.4999)
            for filter in coefficients {
                total += filter.magnitudeDB(at: evaluated, sampleRate: sampleRate)
            }
            return total
        }
    }

    /// `count` frequencies spaced evenly on a log axis from `range.lowerBound`
    /// to `range.upperBound`.
    static func logFrequencies(count: Int, in range: ClosedRange<Double> = EQLimits.frequency) -> [Double] {
        guard count > 1 else { return [range.lowerBound] }
        let low = log10(range.lowerBound)
        let high = log10(range.upperBound)
        return (0..<count).map { index in
            pow(10, low + (high - low) * Double(index) / Double(count - 1))
        }
    }

    /// The largest boost of the bands alone, in dB, across the audible range.
    /// Never negative: a curve that only cuts has a peak boost of 0.
    static func peakBoost(bands: [Band], sampleRate: Double = displaySampleRate) -> Double {
        let values = response(bands: bands, at: logFrequencies(count: 384), sampleRate: sampleRate)
        return max(0, values.max() ?? 0)
    }

    /// How far the loudest point of the curve rises above full scale once the
    /// preamp is applied, in dB. Zero or less means there is enough headroom.
    static func headroomDeficit(bands: [Band], preampDB: Double, sampleRate: Double = displaySampleRate) -> Double {
        peakBoost(bands: bands, sampleRate: sampleRate) + preampDB
    }
}
