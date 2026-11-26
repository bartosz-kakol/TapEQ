//
//  Biquad.swift
//  TapEQ
//
//  Biquad coefficient design (RBJ Audio EQ Cookbook) and magnitude response.
//  Everything here is pure and runs off the audio thread.
//

import Foundation

/// The precision of filter coefficients and filter state.
///
/// Audio enters and leaves the EQ as 32-bit float, but the recursion itself
/// runs in double precision. With 32-bit coefficients a low band on a fast
/// device is badly off (a 20 Hz, Q 10 peak at 192 kHz misses its target by
/// more than 10 dB, and even 30 Hz at 48 kHz misses by over 0.1 dB), because
/// a1 ≈ −2 and a2 ≈ 1 cannot hold the tiny difference that places the poles.
/// Changing this alias to `Float` gives a pure single-precision path at that
/// cost in accuracy; the DSP tests cover the difference.
typealias BiquadScalar = Double

/// Normalised biquad coefficients (a0 == 1).
///
///     y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
struct BiquadCoefficients: Equatable, Sendable {
    var b0: BiquadScalar
    var b1: BiquadScalar
    var b2: BiquadScalar
    var a1: BiquadScalar
    var a2: BiquadScalar

    /// A filter that passes its input through unchanged.
    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    var isIdentity: Bool { self == .identity }

    /// Designs the filter for `band` at `sampleRate`.
    ///
    /// A disabled band, a band with no audible effect, and a band whose
    /// frequency cannot be represented at this sample rate all return
    /// `identity`, which the kernel skips.
    static func design(_ band: Band, sampleRate: Double) -> BiquadCoefficients {
        guard band.isEnabled, sampleRate > 0 else { return .identity }
        let band = band.clamped()
        if band.type.usesGain, band.gain == 0 { return .identity }

        var frequency = band.frequency
        let nyquistLimit = sampleRate * 0.49
        if frequency > nyquistLimit {
            switch band.type {
            case .peak, .highShelf, .lowPass:
                // The whole effect lies above what this rate can carry.
                return .identity
            case .lowShelf, .highPass:
                // The effect covers the whole representable band; keep the
                // corner as high as the rate allows.
                frequency = nyquistLimit
            }
        }

        let amplitude = pow(10, band.gain / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / (2 * band.q)

        let b0, b1, b2, a0, a1, a2: Double
        switch band.type {
        case .peak:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosine
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosine
            a2 = 1 - alpha / amplitude
        case .lowShelf:
            let beta = 2 * amplitude.squareRoot() * alpha
            b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + beta)
            b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine)
            b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - beta)
            a0 = (amplitude + 1) + (amplitude - 1) * cosine + beta
            a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosine)
            a2 = (amplitude + 1) + (amplitude - 1) * cosine - beta
        case .highShelf:
            let beta = 2 * amplitude.squareRoot() * alpha
            b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + beta)
            b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine)
            b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - beta)
            a0 = (amplitude + 1) - (amplitude - 1) * cosine + beta
            a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosine)
            a2 = (amplitude + 1) - (amplitude - 1) * cosine - beta
        case .lowPass:
            b0 = (1 - cosine) / 2
            b1 = 1 - cosine
            b2 = (1 - cosine) / 2
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosine) / 2
            b1 = -(1 + cosine)
            b2 = (1 + cosine) / 2
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        }

        return BiquadCoefficients(
            b0: BiquadScalar(b0 / a0),
            b1: BiquadScalar(b1 / a0),
            b2: BiquadScalar(b2 / a0),
            a1: BiquadScalar(a1 / a0),
            a2: BiquadScalar(a2 / a0)
        )
    }

    /// Linear magnitude of the filter's frequency response at `frequency`.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        if isIdentity { return 1 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega), sin1 = sin(omega)
        let cos2 = cos(2 * omega), sin2 = sin(2 * omega)
        let b0 = Double(b0), b1 = Double(b1), b2 = Double(b2)
        let a1 = Double(a1), a2 = Double(a2)
        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImaginary = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImaginary = -(a1 * sin1 + a2 * sin2)
        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominator = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        guard denominator > 0 else { return 0 }
        return (numerator / denominator).squareRoot()
    }

    /// Magnitude of the filter's frequency response at `frequency`, in dB.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        Decibels.fromLinear(magnitude(at: frequency, sampleRate: sampleRate))
    }
}

/// Conversions between decibels and linear gain.
enum Decibels {
    /// The floor reported for a linear gain of zero.
    static let floor = -200.0

    static func toLinear(_ decibels: Double) -> Double {
        pow(10, decibels / 20)
    }

    static func fromLinear(_ linear: Double) -> Double {
        guard linear > 0 else { return floor }
        return max(floor, 20 * log10(linear))
    }
}
