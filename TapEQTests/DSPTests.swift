//
//  DSPTests.swift
//  TapEQTests
//

import XCTest
@testable import TapEQ

final class DSPTests: XCTestCase {

    // MARK: - Reference maths

    /// Magnitude in dB of the analog prototype each RBJ filter is derived
    /// from, evaluated at the frequency the bilinear transform maps `frequency`
    /// to. The cookbook filters are exact bilinear transforms of these
    /// prototypes, so this is the analytical response of the digital filter.
    private func analyticalDB(_ band: Band, at frequency: Double, sampleRate: Double) -> Double {
        let warped = tan(.pi * frequency / sampleRate) / tan(.pi * band.frequency / sampleRate)
        let amplitude = pow(10, band.gain / 40)
        let q = band.q

        func magnitude(_ real: Double, _ imaginary: Double) -> Double {
            (real * real + imaginary * imaginary).squareRoot()
        }

        let linear: Double
        switch band.type {
        case .lowPass:
            linear = 1 / magnitude(1 - warped * warped, warped / q)
        case .highPass:
            linear = warped * warped / magnitude(1 - warped * warped, warped / q)
        case .peak:
            linear = magnitude(1 - warped * warped, warped * amplitude / q)
                / magnitude(1 - warped * warped, warped / (amplitude * q))
        case .lowShelf:
            let side = warped * amplitude.squareRoot() / q
            linear = amplitude * magnitude(amplitude - warped * warped, side)
                / magnitude(1 - amplitude * warped * warped, side)
        case .highShelf:
            let side = warped * amplitude.squareRoot() / q
            linear = amplitude * magnitude(1 - amplitude * warped * warped, side)
                / magnitude(amplitude - warped * warped, side)
        }
        return 20 * log10(linear)
    }

    /// Amplitude of the `frequency` component of `signal`, by projecting onto
    /// a sine and a cosine. `signal` must span a whole number of cycles.
    private func amplitude(of signal: ArraySlice<Float>, frequency: Double, sampleRate: Double) -> Double {
        var sineSum = 0.0, cosineSum = 0.0
        for (offset, sample) in signal.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(offset) / sampleRate
            sineSum += Double(sample) * sin(phase)
            cosineSum += Double(sample) * cos(phase)
        }
        let count = Double(signal.count)
        return 2 * (sineSum * sineSum + cosineSum * cosineSum).squareRoot() / count
    }

    private func sine(frequency: Double, amplitude: Double, sampleRate: Double, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    private let probeFrequencies: [Double] = [20, 45, 100, 250, 640, 1_000, 2_500, 6_000, 12_000, 18_000]

    private var bandsUnderTest: [Band] {
        var bands: [Band] = []
        for type in BandType.allCases {
            for frequency in [40.0, 250, 1_000, 4_000, 12_000] {
                for q in [0.3, 0.707, 2.5, 10] {
                    if type.usesGain {
                        for gain in [-24.0, -6, 3, 12, 24] {
                            bands.append(Band(type: type, frequency: frequency, gain: gain, q: q))
                        }
                    } else {
                        bands.append(Band(type: type, frequency: frequency, q: q))
                    }
                }
            }
        }
        return bands
    }

    // MARK: - Magnitude response

    func testEveryBandTypeMatchesAnalyticalResponse() {
        for sampleRate in [44_100.0, 48_000, 96_000] {
            for band in bandsUnderTest {
                let coefficients = BiquadCoefficients.design(band, sampleRate: sampleRate)
                for frequency in probeFrequencies {
                    let expected = analyticalDB(band, at: frequency, sampleRate: sampleRate)
                    // Deep in a stop band the absolute level no longer matters.
                    guard expected > -100 else { continue }
                    let actual = coefficients.magnitudeDB(at: frequency, sampleRate: sampleRate)
                    XCTAssertEqual(
                        actual, expected, accuracy: 0.1,
                        "\(band.type) f0=\(band.frequency) gain=\(band.gain) Q=\(band.q) at \(frequency) Hz, fs=\(sampleRate)"
                    )
                }
            }
        }
    }

    func testPeakHitsItsGainAtCentreAndIsFlatFarAway() {
        let band = Band(type: .peak, frequency: 1_000, gain: 9, q: 4)
        let coefficients = BiquadCoefficients.design(band, sampleRate: 48_000)
        XCTAssertEqual(coefficients.magnitudeDB(at: 1_000, sampleRate: 48_000), 9, accuracy: 0.001)
        XCTAssertEqual(coefficients.magnitudeDB(at: 20, sampleRate: 48_000), 0, accuracy: 0.05)
        XCTAssertEqual(coefficients.magnitudeDB(at: 20_000, sampleRate: 48_000), 0, accuracy: 0.05)
    }

    func testShelvesReachFullGainAtTheirEnd() {
        let low = BiquadCoefficients.design(Band(type: .lowShelf, frequency: 200, gain: 6), sampleRate: 48_000)
        XCTAssertEqual(low.magnitudeDB(at: 1, sampleRate: 48_000), 6, accuracy: 0.01)
        XCTAssertEqual(low.magnitudeDB(at: 200, sampleRate: 48_000), 3, accuracy: 0.01)
        XCTAssertEqual(low.magnitudeDB(at: 20_000, sampleRate: 48_000), 0, accuracy: 0.01)

        let high = BiquadCoefficients.design(Band(type: .highShelf, frequency: 4_000, gain: -8), sampleRate: 48_000)
        XCTAssertEqual(high.magnitudeDB(at: 23_990, sampleRate: 48_000), -8, accuracy: 0.01)
        XCTAssertEqual(high.magnitudeDB(at: 4_000, sampleRate: 48_000), -4, accuracy: 0.01)
        XCTAssertEqual(high.magnitudeDB(at: 20, sampleRate: 48_000), 0, accuracy: 0.01)
    }

    func testPassFiltersAreThreeDBDownAtTheCornerWithButterworthQ() {
        let q = 1 / 2.0.squareRoot()
        let lowPass = BiquadCoefficients.design(Band(type: .lowPass, frequency: 2_000, q: q), sampleRate: 48_000)
        XCTAssertEqual(lowPass.magnitudeDB(at: 2_000, sampleRate: 48_000), -3.0103, accuracy: 0.01)
        XCTAssertEqual(lowPass.magnitudeDB(at: 20, sampleRate: 48_000), 0, accuracy: 0.01)

        let highPass = BiquadCoefficients.design(Band(type: .highPass, frequency: 80, q: q), sampleRate: 48_000)
        XCTAssertEqual(highPass.magnitudeDB(at: 80, sampleRate: 48_000), -3.0103, accuracy: 0.01)
        XCTAssertEqual(highPass.magnitudeDB(at: 10_000, sampleRate: 48_000), 0, accuracy: 0.01)
    }

    /// The case that rules out single-precision coefficients: a narrow band
    /// at the bottom of the range on a fast device.
    func testLowBandOnFastDeviceStaysAccurate() {
        let band = Band(type: .peak, frequency: 20, gain: 12, q: 10)
        let sampleRate = 192_000.0
        let coefficients = BiquadCoefficients.design(band, sampleRate: sampleRate)
        for frequency in [10.0, 18, 19.5, 20, 20.5, 22, 40] {
            XCTAssertEqual(
                coefficients.magnitudeDB(at: frequency, sampleRate: sampleRate),
                analyticalDB(band, at: frequency, sampleRate: sampleRate),
                accuracy: 0.1
            )
        }
    }

    func testProcessedSineMatchesAnalyticalGainForEveryBandType() {
        let sampleRate = 48_000.0
        let bands = [
            Band(type: .peak, frequency: 1_000, gain: 6, q: 1.4),
            Band(type: .peak, frequency: 60, gain: -9, q: 3),
            Band(type: .lowShelf, frequency: 150, gain: 8, q: 0.707),
            Band(type: .highShelf, frequency: 6_000, gain: -5, q: 0.707),
            Band(type: .lowPass, frequency: 3_000, q: 0.707),
            Band(type: .highPass, frequency: 300, q: 1.2),
        ]
        // Whole cycles in 4800 samples at 48 kHz for every one of these.
        let tones: [Double] = [50, 100, 300, 1_000, 3_000, 8_000]

        for band in bands {
            for tone in tones {
                let processor = EQProcessor(sampleRate: sampleRate)
                processor.update(bands: [band], preampDB: 0)
                var left = sine(frequency: tone, amplitude: 0.25, sampleRate: sampleRate, count: 48_000)
                var right = left
                processor.process(left: &left, right: &right)

                let measured = amplitude(of: left[43_200...], frequency: tone, sampleRate: sampleRate)
                let measuredDB = 20 * log10(measured / 0.25)
                let expected = analyticalDB(band, at: tone, sampleRate: sampleRate)
                XCTAssertEqual(measuredDB, expected, accuracy: 0.1, "\(band.type) f0=\(band.frequency) at \(tone) Hz")
                XCTAssertEqual(left, right, "Both channels run the same filter")
            }
        }
    }

    func testPreampScalesTheOutput() {
        let processor = EQProcessor(sampleRate: 48_000)
        processor.update(bands: [], preampDB: -6)
        var left = sine(frequency: 1_000, amplitude: 0.5, sampleRate: 48_000, count: 4_800)
        var right = left
        processor.process(left: &left, right: &right)
        let measured = amplitude(of: left[...], frequency: 1_000, sampleRate: 48_000)
        XCTAssertEqual(20 * log10(measured / 0.5), -6, accuracy: 0.001)
    }

    // MARK: - Transparency

    private func noise(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max) * 0.9
        }
    }

    func testFlatPresetIsBitTransparent() {
        let flatCurves: [[Band]] = [
            [],
            [Band(type: .peak, frequency: 100, gain: 0), Band(type: .highShelf, frequency: 8_000, gain: 0)],
            [Band(type: .peak, frequency: 1_000, gain: 12, isEnabled: false),
             Band(type: .lowPass, frequency: 200, isEnabled: false)],
        ]
        for bands in flatCurves {
            let processor = EQProcessor(sampleRate: 48_000)
            processor.update(bands: bands, preampDB: 0)
            let input = noise(count: 8_192, seed: 42)
            var left = input
            var right = noise(count: 8_192, seed: 7)
            let rightInput = right
            processor.process(left: &left, right: &right)
            XCTAssertEqual(left, input)
            XCTAssertEqual(right, rightInput)
        }
    }

    func testKernelWithNoPublishedCoefficientsPassesAudioThrough() {
        let processor = EQProcessor(sampleRate: 48_000)
        let input = noise(count: 1_024, seed: 3)
        var left = input, right = input
        processor.process(left: &left, right: &right)
        XCTAssertEqual(left, input)
    }

    func testSoftClipperIsTransparentBelowTheKneeAndBoundedAbove() {
        for value in stride(from: -SoftClipper.knee, through: SoftClipper.knee, by: 0.05) {
            XCTAssertEqual(SoftClipper.clip(value), value)
        }
        var previous = SoftClipper.clip(SoftClipper.knee)
        for value in stride(from: SoftClipper.knee + 0.01, through: 20, by: 0.01) {
            let clipped = SoftClipper.clip(value)
            XCTAssertLessThanOrEqual(clipped, 1)
            XCTAssertGreaterThanOrEqual(clipped, previous, "The curve never folds back")
            XCTAssertEqual(SoftClipper.clip(-value), -clipped)
            previous = clipped
        }
        XCTAssertEqual(SoftClipper.clip(.nan), 0)
        XCTAssertEqual(SoftClipper.clip(.infinity), 1)
        XCTAssertEqual(SoftClipper.clip(-.infinity), -1)
    }

    // MARK: - Coefficient swaps

    /// Largest jump between neighbouring samples, ignoring the first `skip`.
    private func largestStep(in signal: [Float], skipping skip: Int = 0) -> Double {
        var largest = 0.0
        for index in max(1, skip)..<signal.count {
            largest = max(largest, abs(Double(signal[index]) - Double(signal[index - 1])))
        }
        return largest
    }

    /// Runs a sine through `processor` in device-sized blocks, calling
    /// `change` once before the block that starts at `changeAt`.
    private func run(
        _ processor: EQProcessor,
        input: [Float],
        blockSize: Int = 512,
        changeAt: Int,
        change: () -> Void
    ) -> [Float] {
        var output: [Float] = []
        var changed = false
        var position = 0
        while position < input.count {
            if !changed, position >= changeAt {
                change()
                changed = true
            }
            let end = min(position + blockSize, input.count)
            var left = Array(input[position..<end])
            var right = left
            processor.process(left: &left, right: &right)
            output += left
            position = end
        }
        return output
    }

    func testCoefficientSwapOnSineHasNoDiscontinuity() {
        let sampleRate = 48_000.0
        let tone = 440.0
        let inputAmplitude = 0.25
        let input = sine(frequency: tone, amplitude: inputAmplitude, sampleRate: sampleRate, count: 48_000)

        let before = [Band(type: .peak, frequency: 440, gain: 12, q: 1), Band(type: .lowShelf, frequency: 200, gain: 6)]
        let after = [Band(type: .peak, frequency: 440, gain: -12, q: 4), Band(type: .highPass, frequency: 300, q: 0.9)]

        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(bands: before, preampDB: 0)
        let output = run(processor, input: input, changeAt: 24_000) {
            processor.update(bands: after, preampDB: -3)
        }

        // The steepest a clean sine of the loudest steady-state level can be.
        let loudestGain = Decibels.toLinear(
            max(EQCurve.response(bands: before, at: [tone])[0], EQCurve.response(bands: after, preampDB: -3, at: [tone])[0])
        )
        let steepestCleanStep = inputAmplitude * loudestGain * 2 * Double.pi * tone / sampleRate
        XCTAssertLessThanOrEqual(largestStep(in: output, skipping: 4_800), steepestCleanStep * 1.1)

        // And the swap really happened: the tail sits at the new level.
        let tail = amplitude(of: output[43_200...], frequency: tone, sampleRate: sampleRate)
        let expectedTail = EQCurve.response(bands: after, preampDB: -3, at: [tone])[0]
        XCTAssertEqual(20 * log10(tail / inputAmplitude), expectedTail, accuracy: 0.1)
    }

    func testPreampJumpIsRampedNotStepped() {
        let sampleRate = 48_000.0
        let tone = 1_000.0
        let input = sine(frequency: tone, amplitude: 0.5, sampleRate: sampleRate, count: 24_000)
        let steepestCleanStep = 0.5 * 2 * Double.pi * tone / sampleRate

        let ramped = EQProcessor(sampleRate: sampleRate)
        ramped.update(bands: [], preampDB: -24)
        // 12_012 is a crest of the sine, where an instant gain change is worst.
        let rampedOutput = run(ramped, input: input, blockSize: 12, changeAt: 12_012) {
            ramped.update(bands: [], preampDB: 0)
        }
        XCTAssertLessThanOrEqual(largestStep(in: rampedOutput), steepestCleanStep * 1.1)

        // Control: without a ramp the same change produces an obvious step,
        // so the assertion above is really testing the ramp.
        let abrupt = EQProcessor(sampleRate: sampleRate, rampDuration: 0)
        abrupt.update(bands: [], preampDB: -24)
        let abruptOutput = run(abrupt, input: input, blockSize: 12, changeAt: 12_012) {
            abrupt.update(bands: [], preampDB: 0)
        }
        XCTAssertGreaterThan(largestStep(in: abruptOutput), steepestCleanStep * 3)
    }

    func testEnablingAndDisablingABandIsSmooth() {
        let sampleRate = 48_000.0
        let tone = 100.0
        let input = sine(frequency: tone, amplitude: 0.25, sampleRate: sampleRate, count: 48_000)
        var band = Band(type: .lowShelf, frequency: 200, gain: 12)
        let boostedStep = 0.25 * Decibels.toLinear(12) * 2 * Double.pi * tone / sampleRate

        let processor = EQProcessor(sampleRate: sampleRate)
        processor.update(bands: [band], preampDB: 0)
        var output = run(processor, input: input, changeAt: 12_000) {
            band.isEnabled = false
            processor.update(bands: [band], preampDB: 0)
        }
        XCTAssertLessThanOrEqual(largestStep(in: output, skipping: 4_800), boostedStep * 1.1)
        // Once the ramp is over a disabled band is exactly transparent.
        XCTAssertEqual(Array(output[40_000...]), Array(input[40_000...]))

        output = run(processor, input: input, changeAt: 12_000) {
            band.isEnabled = true
            processor.update(bands: [band], preampDB: 0)
        }
        XCTAssertLessThanOrEqual(largestStep(in: output), boostedStep * 1.1)
    }

    func testRapidPublishingKeepsOnlyTheNewestSetAndFreesTheRest() {
        let processor = EQProcessor(sampleRate: 48_000)
        var left = sine(frequency: 1_000, amplitude: 0.25, sampleRate: 48_000, count: 256)
        var right = left
        for step in 0..<2_000 {
            // Several publishes between audio callbacks, as a dragged slider does.
            processor.update(bands: [Band(type: .peak, frequency: 1_000, gain: Double(step % 24) - 12)], preampDB: 0)
            processor.update(bands: [Band(type: .peak, frequency: 1_000, gain: 6)], preampDB: 0)
            if step.isMultiple(of: 3) {
                processor.process(left: &left, right: &right)
                left = sine(frequency: 1_000, amplitude: 0.25, sampleRate: 48_000, count: 256)
                right = left
            }
        }
        // Settle on the last published curve.
        var settleLeft = sine(frequency: 1_000, amplitude: 0.25, sampleRate: 48_000, count: 48_000)
        var settleRight = settleLeft
        processor.process(left: &settleLeft, right: &settleRight)
        let measured = amplitude(of: settleLeft[43_200...], frequency: 1_000, sampleRate: 48_000)
        XCTAssertEqual(20 * log10(measured / 0.25), 6, accuracy: 0.01)
    }

    // MARK: - Curve

    func testCombinedResponseIsTheSumOfItsBandsPlusPreamp() {
        let bands = [
            Band(type: .lowShelf, frequency: 120, gain: 5),
            Band(type: .peak, frequency: 2_000, gain: -4, q: 2),
            Band(type: .highShelf, frequency: 9_000, gain: 3),
            Band(type: .peak, frequency: 500, gain: 10, isEnabled: false),
        ]
        let frequencies: [Double] = [30, 120, 500, 2_000, 9_000, 16_000]
        let combined = EQCurve.response(bands: bands, preampDB: -2, at: frequencies, sampleRate: 48_000)
        for (index, frequency) in frequencies.enumerated() {
            let expected = bands.filter(\.isEnabled).reduce(-2.0) {
                $0 + analyticalDB($1, at: frequency, sampleRate: 48_000)
            }
            XCTAssertEqual(combined[index], expected, accuracy: 0.1)
        }
    }

    func testResponseIgnoresBandsBeyondTheLimit() {
        let bands = (0..<EQLimits.maxBands + 3).map { _ in Band(type: .peak, frequency: 1_000, gain: 1, q: 1) }
        let value = EQCurve.response(bands: bands, at: [1_000])[0]
        XCTAssertEqual(value, Double(EQLimits.maxBands), accuracy: 0.001)
    }

    func testLogFrequenciesSpanTheAudibleRange() {
        let frequencies = EQCurve.logFrequencies(count: 101)
        XCTAssertEqual(frequencies.first!, 20, accuracy: 1e-9)
        XCTAssertEqual(frequencies.last!, 20_000, accuracy: 1e-6)
        XCTAssertEqual(frequencies[50], (20.0 * 20_000).squareRoot(), accuracy: 1e-6)
    }

    func testHeadroomDeficit() {
        let boost = [Band(type: .peak, frequency: 1_000, gain: 9, q: 1)]
        XCTAssertEqual(EQCurve.peakBoost(bands: boost), 9, accuracy: 0.05)
        XCTAssertEqual(EQCurve.headroomDeficit(bands: boost, preampDB: -9), 0, accuracy: 0.05)
        XCTAssertGreaterThan(EQCurve.headroomDeficit(bands: boost, preampDB: -3), 5.9)

        let cut = [Band(type: .peak, frequency: 1_000, gain: -9, q: 1)]
        XCTAssertEqual(EQCurve.peakBoost(bands: cut), 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(EQCurve.headroomDeficit(bands: cut, preampDB: 0), 0)
    }

    // MARK: - Parameter handling

    func testOutOfRangeParametersAreClamped() {
        let wild = Band(type: .peak, frequency: 5, gain: 90, q: 0).clamped()
        XCTAssertEqual(wild.frequency, 20)
        XCTAssertEqual(wild.gain, 24)
        XCTAssertEqual(wild.q, 0.1)

        let broken = Band(type: .peak, frequency: .nan, gain: .infinity, q: -.infinity).clamped()
        XCTAssertEqual(broken.frequency, 1_000)
        XCTAssertEqual(broken.gain, 0)
        XCTAssertEqual(broken.q, EQLimits.defaultQ)
    }

    func testBandsAboveNyquistDoNotBlowUp() {
        // A hands-free Bluetooth profile can run as low as 8 kHz.
        let sampleRate = 8_000.0
        for type in BandType.allCases {
            let coefficients = BiquadCoefficients.design(Band(type: type, frequency: 12_000, gain: 12), sampleRate: sampleRate)
            for value in [coefficients.b0, coefficients.b1, coefficients.b2, coefficients.a1, coefficients.a2] {
                XCTAssertTrue(value.isFinite)
            }
            // Poles inside the unit circle.
            XCTAssertLessThan(abs(coefficients.a2), 1)
            XCTAssertLessThan(abs(coefficients.a1), 1 + coefficients.a2)
        }
    }
}
