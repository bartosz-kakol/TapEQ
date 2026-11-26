//
//  SoftClipper.swift
//  TapEQ
//
//  The safety limiter at the very end of the chain. It leaves everything
//  below the knee untouched and bends louder samples smoothly toward full
//  scale, so a boosted curve distorts gently instead of wrapping or hard
//  clipping in the device.
//

import Foundation

enum SoftClipper {
    /// Samples at or below this level pass through bit for bit (about −1.4 dBFS).
    static let knee: BiquadScalar = 0.85

    /// Clips one sample. The curve is continuous with slope 1 at the knee and
    /// approaches ±1 without ever reaching it.
    @inline(__always)
    static func clip(_ sample: BiquadScalar) -> BiquadScalar {
        let magnitude = abs(sample)
        if magnitude <= knee { return sample }
        // NaN fails the comparison above and lands here; silence is the only
        // safe thing to send to a speaker.
        guard magnitude.isFinite else { return sample.isNaN ? 0 : (sample > 0 ? 1 : -1) }
        let range = 1 - knee
        let shaped = knee + range * tanh((magnitude - knee) / range)
        return sample < 0 ? -shaped : shaped
    }
}
