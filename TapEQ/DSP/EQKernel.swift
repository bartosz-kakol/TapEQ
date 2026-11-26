//
//  EQKernel.swift
//  TapEQ
//
//  The real-time EQ: a cascade of Direct Form II Transposed biquads with a
//  preamp, fed by lock-free coefficient updates.
//
//  Threading model
//  ---------------
//  Two threads touch a kernel. The control thread (main) designs a
//  coefficient set and calls `publish`. The audio thread calls `process`.
//  They share exactly two atomic cells:
//
//    pending  control → audio   the newest set that the audio thread has not
//                               picked up yet
//    retired  audio → control   the set the audio thread has just stopped
//                               using, waiting to be freed off the audio thread
//
//  The audio thread never frees memory. It only adopts a pending set when the
//  retired cell is empty, so one cell is always enough.
//
//  Everything `process` touches is plain memory behind unsafe pointers: no
//  classes, arrays, existentials or closures, so there is nothing for Swift
//  to retain, release or allocate on the audio thread.
//

import Foundation
import RTAtomics

// MARK: - Coefficient sets

/// An immutable block of coefficients for one preset at one sample rate.
///
/// Layout: `[preamp gain, b0, b1, b2, a1, a2, b0, b1, …]` with
/// `EQLimits.maxBands` bands. Unused bands hold the identity filter.
enum EQCoefficientSet {
    static let scalarsPerBand = 5
    static let scalarCount = 1 + EQLimits.maxBands * scalarsPerBand

    /// Designs every band and returns a freshly allocated set.
    /// The caller owns it until it is handed to `EQKernel.publish`.
    static func make(bands: [Band], preampDB: Double, sampleRate: Double) -> UnsafeMutablePointer<BiquadScalar> {
        let set = UnsafeMutablePointer<BiquadScalar>.allocate(capacity: scalarCount)
        let clampedPreamp = min(max(preampDB, EQLimits.preamp.lowerBound), EQLimits.preamp.upperBound)
        set[0] = BiquadScalar(Decibels.toLinear(clampedPreamp.isFinite ? clampedPreamp : 0))
        for index in 0..<EQLimits.maxBands {
            let coefficients = index < bands.count
                ? BiquadCoefficients.design(bands[index], sampleRate: sampleRate)
                : .identity
            let base = 1 + index * scalarsPerBand
            set[base] = coefficients.b0
            set[base + 1] = coefficients.b1
            set[base + 2] = coefficients.b2
            set[base + 3] = coefficients.a1
            set[base + 4] = coefficients.a2
        }
        return set
    }

    static func free(_ set: UnsafeMutablePointer<BiquadScalar>) {
        set.deallocate()
    }
}

// MARK: - Kernel state

/// Audio-thread state of one band: the coefficients in use right now, where
/// they are heading, and the filter memory of both channels.
struct EQBandState {
    var current = BiquadCoefficients.identity
    var target = BiquadCoefficients.identity
    /// Added to `current` once per sample while a ramp is running.
    var step = BiquadCoefficients(b0: 0, b1: 0, b2: 0, a1: 0, a2: 0)
    var z1Left: BiquadScalar = 0
    var z2Left: BiquadScalar = 0
    var z1Right: BiquadScalar = 0
    var z2Right: BiquadScalar = 0
}

/// One stereo EQ chain. Lives in manually managed memory; see `EQProcessor`
/// for the owning object used off the audio thread.
struct EQKernel {
    fileprivate let pending: UnsafeMutablePointer<tapeq_atomic_ptr>
    fileprivate let retired: UnsafeMutablePointer<tapeq_atomic_ptr>
    fileprivate let bands: UnsafeMutablePointer<EQBandState>

    // Audio-thread only below this line.
    fileprivate var currentSet: UnsafeMutablePointer<BiquadScalar>?
    fileprivate var gain: BiquadScalar = 1
    fileprivate var targetGain: BiquadScalar = 1
    fileprivate var gainStep: BiquadScalar = 0
    fileprivate var rampRemaining = 0
    fileprivate let rampLength: Int
    /// False until the first set has been adopted. The first set is applied
    /// at once, with no ramp from the flat start-up state.
    fileprivate var isPrimed = false

    // MARK: Lifecycle (control thread)

    /// Allocates a kernel.
    /// - Parameter rampLength: Samples over which a coefficient change is
    ///   spread. Zero applies changes at once.
    static func create(rampLength: Int) -> UnsafeMutablePointer<EQKernel> {
        let pending = UnsafeMutablePointer<tapeq_atomic_ptr>.allocate(capacity: 1)
        pending.initialize(to: tapeq_atomic_ptr())
        let retired = UnsafeMutablePointer<tapeq_atomic_ptr>.allocate(capacity: 1)
        retired.initialize(to: tapeq_atomic_ptr())
        let bands = UnsafeMutablePointer<EQBandState>.allocate(capacity: EQLimits.maxBands)
        bands.initialize(repeating: EQBandState(), count: EQLimits.maxBands)
        let kernel = UnsafeMutablePointer<EQKernel>.allocate(capacity: 1)
        kernel.initialize(to: EQKernel(pending: pending, retired: retired, bands: bands, rampLength: max(0, rampLength)))
        return kernel
    }

    /// Frees a kernel and every coefficient set it still holds.
    /// The audio thread must have stopped calling `process` for good.
    static func destroy(_ kernel: UnsafeMutablePointer<EQKernel>) {
        for cell in [kernel.pointee.pending, kernel.pointee.retired] {
            if let leftover = tapeq_atomic_ptr_exchange(cell, nil) {
                EQCoefficientSet.free(leftover.assumingMemoryBound(to: BiquadScalar.self))
            }
            cell.deinitialize(count: 1)
            cell.deallocate()
        }
        if let set = kernel.pointee.currentSet {
            EQCoefficientSet.free(set)
        }
        kernel.pointee.bands.deinitialize(count: EQLimits.maxBands)
        kernel.pointee.bands.deallocate()
        kernel.deinitialize(count: 1)
        kernel.deallocate()
    }

    /// Hands `set` to the audio thread and frees whatever it has given back.
    /// The kernel takes ownership of `set`. Control thread only.
    static func publish(_ kernel: UnsafeMutablePointer<EQKernel>, _ set: UnsafeMutablePointer<BiquadScalar>) {
        collectRetired(kernel)
        // A set that was still waiting has never been seen by the audio
        // thread, so it can be freed here.
        if let unused = tapeq_atomic_ptr_exchange(kernel.pointee.pending, UnsafeMutableRawPointer(set)) {
            EQCoefficientSet.free(unused.assumingMemoryBound(to: BiquadScalar.self))
        }
    }

    /// Frees the set the audio thread has stopped using, if any.
    /// Control thread only.
    static func collectRetired(_ kernel: UnsafeMutablePointer<EQKernel>) {
        if let old = tapeq_atomic_ptr_exchange(kernel.pointee.retired, nil) {
            EQCoefficientSet.free(old.assumingMemoryBound(to: BiquadScalar.self))
        }
    }

    // MARK: Processing (audio thread)

    /// Filters `count` samples of both channels in place.
    static func process(
        _ kernel: UnsafeMutablePointer<EQKernel>,
        left: UnsafeMutablePointer<BiquadScalar>,
        right: UnsafeMutablePointer<BiquadScalar>,
        count: Int
    ) {
        guard count > 0 else { return }
        adoptPending(kernel)

        var offset = 0
        if kernel.pointee.rampRemaining > 0 {
            let rampCount = min(count, kernel.pointee.rampRemaining)
            processRamping(kernel, left: left, right: right, count: rampCount)
            kernel.pointee.rampRemaining -= rampCount
            if kernel.pointee.rampRemaining == 0 {
                finishRamp(kernel)
            }
            offset = rampCount
        }
        if offset < count {
            processSteady(kernel, left: left + offset, right: right + offset, count: count - offset)
        }
        flushDenormals(kernel)
    }

    /// Picks up a newly published set, if there is one and there is room to
    /// hand the old one back.
    @inline(__always)
    private static func adoptPending(_ kernel: UnsafeMutablePointer<EQKernel>) {
        guard tapeq_atomic_ptr_load(kernel.pointee.retired) == nil,
              let raw = tapeq_atomic_ptr_exchange(kernel.pointee.pending, nil)
        else { return }
        let set = raw.assumingMemoryBound(to: BiquadScalar.self)
        if let old = kernel.pointee.currentSet {
            tapeq_atomic_ptr_store(kernel.pointee.retired, UnsafeMutableRawPointer(old))
        }
        kernel.pointee.currentSet = set

        let rampLength = kernel.pointee.rampLength
        let ramps = kernel.pointee.isPrimed && rampLength > 0
        let scale = ramps ? 1 / BiquadScalar(rampLength) : 0
        let bands = kernel.pointee.bands

        kernel.pointee.targetGain = set[0]
        var index = 0
        while index < EQLimits.maxBands {
            let base = 1 + index * EQCoefficientSet.scalarsPerBand
            let target = BiquadCoefficients(
                b0: set[base], b1: set[base + 1], b2: set[base + 2], a1: set[base + 3], a2: set[base + 4]
            )
            bands[index].target = target
            if ramps {
                let current = bands[index].current
                bands[index].step = BiquadCoefficients(
                    b0: (target.b0 - current.b0) * scale,
                    b1: (target.b1 - current.b1) * scale,
                    b2: (target.b2 - current.b2) * scale,
                    a1: (target.a1 - current.a1) * scale,
                    a2: (target.a2 - current.a2) * scale
                )
            } else {
                bands[index].current = target
            }
            index += 1
        }

        if ramps {
            kernel.pointee.gainStep = (kernel.pointee.targetGain - kernel.pointee.gain) * scale
            kernel.pointee.rampRemaining = rampLength
        } else {
            kernel.pointee.gain = kernel.pointee.targetGain
            kernel.pointee.rampRemaining = 0
            kernel.pointee.isPrimed = true
        }
    }

    /// Runs the cascade while coefficients and gain move toward their
    /// targets by one step per sample.
    ///
    /// The stable region of (a1, a2) is convex, so every point on the
    /// straight line between two stable filters is itself stable.
    private static func processRamping(
        _ kernel: UnsafeMutablePointer<EQKernel>,
        left: UnsafeMutablePointer<BiquadScalar>,
        right: UnsafeMutablePointer<BiquadScalar>,
        count: Int
    ) {
        var gain = kernel.pointee.gain
        let gainStep = kernel.pointee.gainStep
        var sample = 0
        while sample < count {
            gain += gainStep
            left[sample] *= gain
            right[sample] *= gain
            sample += 1
        }
        kernel.pointee.gain = gain

        let bands = kernel.pointee.bands
        var index = 0
        while index < EQLimits.maxBands {
            let band = bands + index
            index += 1
            if isIdentity(band.pointee.current) && isIdentity(band.pointee.target) { continue }

            var c = band.pointee.current
            let step = band.pointee.step
            var z1L = band.pointee.z1Left, z2L = band.pointee.z2Left
            var z1R = band.pointee.z1Right, z2R = band.pointee.z2Right
            sample = 0
            while sample < count {
                c.b0 += step.b0
                c.b1 += step.b1
                c.b2 += step.b2
                c.a1 += step.a1
                c.a2 += step.a2

                let xL = left[sample]
                let yL = c.b0 * xL + z1L
                z1L = c.b1 * xL - c.a1 * yL + z2L
                z2L = c.b2 * xL - c.a2 * yL
                left[sample] = yL

                let xR = right[sample]
                let yR = c.b0 * xR + z1R
                z1R = c.b1 * xR - c.a1 * yR + z2R
                z2R = c.b2 * xR - c.a2 * yR
                right[sample] = yR
                sample += 1
            }
            band.pointee.current = c
            band.pointee.z1Left = z1L
            band.pointee.z2Left = z2L
            band.pointee.z1Right = z1R
            band.pointee.z2Right = z2R
        }
    }

    /// Lands exactly on the targets, removing the rounding left by the steps.
    @inline(__always)
    private static func finishRamp(_ kernel: UnsafeMutablePointer<EQKernel>) {
        kernel.pointee.gain = kernel.pointee.targetGain
        let bands = kernel.pointee.bands
        var index = 0
        while index < EQLimits.maxBands {
            bands[index].current = bands[index].target
            if isIdentity(bands[index].target) {
                // The band is skipped from now on; do not keep stale memory
                // around for the day it is switched back on.
                bands[index].z1Left = 0
                bands[index].z2Left = 0
                bands[index].z1Right = 0
                bands[index].z2Right = 0
            }
            index += 1
        }
    }

    /// Runs the cascade with fixed coefficients.
    private static func processSteady(
        _ kernel: UnsafeMutablePointer<EQKernel>,
        left: UnsafeMutablePointer<BiquadScalar>,
        right: UnsafeMutablePointer<BiquadScalar>,
        count: Int
    ) {
        let gain = kernel.pointee.gain
        var sample = 0
        if gain != 1 {
            while sample < count {
                left[sample] *= gain
                right[sample] *= gain
                sample += 1
            }
        }

        let bands = kernel.pointee.bands
        var index = 0
        while index < EQLimits.maxBands {
            let band = bands + index
            index += 1
            let c = band.pointee.current
            if isIdentity(c) { continue }

            var z1L = band.pointee.z1Left, z2L = band.pointee.z2Left
            var z1R = band.pointee.z1Right, z2R = band.pointee.z2Right
            sample = 0
            while sample < count {
                let xL = left[sample]
                let yL = c.b0 * xL + z1L
                z1L = c.b1 * xL - c.a1 * yL + z2L
                z2L = c.b2 * xL - c.a2 * yL
                left[sample] = yL

                let xR = right[sample]
                let yR = c.b0 * xR + z1R
                z1R = c.b1 * xR - c.a1 * yR + z2R
                z2R = c.b2 * xR - c.a2 * yR
                right[sample] = yR
                sample += 1
            }
            band.pointee.z1Left = z1L
            band.pointee.z2Left = z2L
            band.pointee.z1Right = z1R
            band.pointee.z2Right = z2R
        }
    }

    /// Filter memory decaying toward zero ends up in denormal range, which is
    /// very slow on Intel. Snap it to zero once it is far below audibility.
    @inline(__always)
    private static func flushDenormals(_ kernel: UnsafeMutablePointer<EQKernel>) {
        let bands = kernel.pointee.bands
        let threshold: BiquadScalar = 1e-30
        var index = 0
        while index < EQLimits.maxBands {
            if abs(bands[index].z1Left) < threshold { bands[index].z1Left = 0 }
            if abs(bands[index].z2Left) < threshold { bands[index].z2Left = 0 }
            if abs(bands[index].z1Right) < threshold { bands[index].z1Right = 0 }
            if abs(bands[index].z2Right) < threshold { bands[index].z2Right = 0 }
            index += 1
        }
    }

    @inline(__always)
    private static func isIdentity(_ c: BiquadCoefficients) -> Bool {
        c.b0 == 1 && c.b1 == 0 && c.b2 == 0 && c.a1 == 0 && c.a2 == 0
    }
}

// MARK: - Owner

/// Owns one `EQKernel` on behalf of non-real-time code.
///
/// The control thread calls `update`; the audio thread is given `kernel` and
/// calls `EQKernel.process` on it directly. The processor must outlive every
/// audio callback that could still use the kernel.
final class EQProcessor {
    /// How long a coefficient or preamp change takes to settle.
    static let rampDuration = 0.02

    let kernel: UnsafeMutablePointer<EQKernel>
    private(set) var sampleRate: Double

    init(sampleRate: Double, rampDuration: Double = EQProcessor.rampDuration) {
        self.sampleRate = sampleRate
        kernel = EQKernel.create(rampLength: Int((sampleRate * rampDuration).rounded()))
    }

    deinit {
        EQKernel.destroy(kernel)
    }

    /// Designs coefficients for the given curve and hands them to the audio
    /// thread. Safe to call as often as the UI likes.
    func update(bands: [Band], preampDB: Double) {
        EQKernel.publish(kernel, EQCoefficientSet.make(bands: bands, preampDB: preampDB, sampleRate: sampleRate))
    }

    /// Frees coefficient sets the audio thread has finished with.
    func collectGarbage() {
        EQKernel.collectRetired(kernel)
    }

    /// Filters two equally long channels in place. For tests and offline use;
    /// the audio thread calls `EQKernel.process` directly.
    func process(left: inout [Float], right: inout [Float]) {
        precondition(left.count == right.count)
        var wideLeft = left.map { BiquadScalar($0) }
        var wideRight = right.map { BiquadScalar($0) }
        wideLeft.withUnsafeMutableBufferPointer { leftBuffer in
            wideRight.withUnsafeMutableBufferPointer { rightBuffer in
                guard let leftBase = leftBuffer.baseAddress, let rightBase = rightBuffer.baseAddress else { return }
                EQKernel.process(kernel, left: leftBase, right: rightBase, count: leftBuffer.count)
            }
        }
        left = wideLeft.map { Float($0) }
        right = wideRight.map { Float($0) }
    }
}
