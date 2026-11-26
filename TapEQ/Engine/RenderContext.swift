//
//  RenderContext.swift
//  TapEQ
//
//  Everything the IOProc touches, and the IOProc body itself.
//
//  Real-time rules for this file: `RenderContext.render` and everything it
//  calls must not allocate, lock, log, dispatch, or touch a class instance.
//  All state lives in memory allocated up front by `RenderMemory` and is
//  reached through unsafe pointers. The control side talks to the audio side
//  only through the atomic cells declared here and in `EQKernel`.
//

import CoreAudio
import Foundation
import RTAtomics

/// The audio-thread view of one tap.
struct TapRenderSlot {
    /// The EQ chain for this tap's preset.
    let kernel: UnsafeMutablePointer<EQKernel>
    /// Index of this tap's buffer in the IOProc's input buffer list.
    let bufferIndex: Int
    /// Interleaved channels in that buffer (1 or 2).
    let channelCount: Int
    /// Frames delivered since the tap last carried a non-zero sample.
    let silentFrames: UnsafeMutablePointer<tapeq_atomic_u64>
    /// Becomes 1 the first time the tap carries a non-zero sample.
    let hasCarriedAudio: UnsafeMutablePointer<tapeq_atomic_u32>
    /// Frames delivered before the first non-zero sample.
    let framesBeforeAudio: UnsafeMutablePointer<tapeq_atomic_u64>
    /// All frames delivered in all-zero blocks since the graph started.
    let totalSilentFrames: UnsafeMutablePointer<tapeq_atomic_u64>
    /// Bit pattern of the largest input magnitude since the control side
    /// last reset it.
    let inputPeak: UnsafeMutablePointer<tapeq_atomic_u32>
}

/// The audio-thread state of one running graph.
struct RenderContext {
    let slots: UnsafeMutablePointer<TapRenderSlot>
    let slotCount: Int

    /// Work buffers of `capacity` frames each.
    let scratchLeft: UnsafeMutablePointer<BiquadScalar>
    let scratchRight: UnsafeMutablePointer<BiquadScalar>
    let mixLeft: UnsafeMutablePointer<BiquadScalar>
    let mixRight: UnsafeMutablePointer<BiquadScalar>
    let capacity: Int

    /// Incremented once per IOProc call. The control side uses it as a
    /// heartbeat.
    let callbackCount: UnsafeMutablePointer<tapeq_atomic_u64>
    /// Calls in which a tap's buffer did not look the way setup expected.
    let layoutMismatches: UnsafeMutablePointer<tapeq_atomic_u64>
    /// Bit pattern of the largest output magnitude since last cleared.
    let outputPeak: UnsafeMutablePointer<tapeq_atomic_u32>
    /// Output sample time minus input sample time of the latest call: the
    /// delay this graph adds between a tap and the device, in frames.
    let throughputFrames: UnsafeMutablePointer<tapeq_atomic_u64>
    /// 1 while the output should be audible, 0 to fade it to silence.
    let fadeTarget: UnsafeMutablePointer<tapeq_atomic_u32>
    /// Change in output gain per sample while fading.
    let fadeStep: BiquadScalar
    /// Current output gain. Audio thread only.
    var fadeGain: BiquadScalar = 0

    // MARK: IOProc body

    /// Reads every tap, runs its EQ, sums the results and writes them to the
    /// first two output channels.
    static func render(
        _ context: UnsafeMutablePointer<RenderContext>,
        input: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>
    ) {
        tapeq_atomic_u64_add(context.pointee.callbackCount, 1)
        let throughput = outputTime.pointee.mSampleTime - inputTime.pointee.mSampleTime
        if throughput >= 0, throughput < 1e9 {
            tapeq_atomic_u64_store(context.pointee.throughputFrames, UInt64(throughput))
        }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let sampleSize = MemoryLayout<Float32>.size

        // Start from silence on every output channel, including the ones
        // beyond the first two that this version never writes.
        var bufferIndex = 0
        while bufferIndex < outputs.count {
            if let data = outputs[bufferIndex].mData {
                memset(data, 0, Int(outputs[bufferIndex].mDataByteSize))
            }
            bufferIndex += 1
        }

        // Where the first two output channels live. Devices present either
        // one interleaved buffer or one buffer per channel.
        var leftOut: UnsafeMutablePointer<Float32>?
        var rightOut: UnsafeMutablePointer<Float32>?
        var leftStride = 1, rightStride = 1
        var frameCount = 0
        if outputs.count > 0, let data = outputs[0].mData, outputs[0].mNumberChannels > 0 {
            let channels = Int(outputs[0].mNumberChannels)
            let base = data.assumingMemoryBound(to: Float32.self)
            frameCount = Int(outputs[0].mDataByteSize) / (sampleSize * channels)
            leftOut = base
            leftStride = channels
            if channels >= 2 {
                rightOut = base + 1
                rightStride = channels
            } else if outputs.count > 1, let second = outputs[1].mData, outputs[1].mNumberChannels > 0 {
                let secondChannels = Int(outputs[1].mNumberChannels)
                rightOut = second.assumingMemoryBound(to: Float32.self)
                rightStride = secondChannels
                frameCount = min(frameCount, Int(outputs[1].mDataByteSize) / (sampleSize * secondChannels))
            }
        }

        let writesOutput = leftOut != nil
        if !writesOutput {
            // Nowhere to play, but the taps are still measured: take the
            // frame count from the first tap that has data.
            frameCount = 0
            var slotIndex = 0
            while slotIndex < context.pointee.slotCount {
                let slot = context.pointee.slots + slotIndex
                slotIndex += 1
                if slot.pointee.bufferIndex < inputs.count, slot.pointee.channelCount > 0 {
                    frameCount = Int(inputs[slot.pointee.bufferIndex].mDataByteSize)
                        / (sampleSize * slot.pointee.channelCount)
                    break
                }
            }
        }
        guard frameCount > 0 else { return }

        let scratchLeft = context.pointee.scratchLeft
        let scratchRight = context.pointee.scratchRight
        let mixLeft = context.pointee.mixLeft
        let mixRight = context.pointee.mixRight
        let capacity = context.pointee.capacity
        var outputPeak: BiquadScalar = 0
        var mismatched = false

        // Work through the callback in pieces no longer than the scratch
        // buffers, so an unusually large device buffer needs no allocation.
        var start = 0
        while start < frameCount {
            let count = min(capacity, frameCount - start)

            var frame = 0
            while frame < count {
                mixLeft[frame] = 0
                mixRight[frame] = 0
                frame += 1
            }

            var slotIndex = 0
            while slotIndex < context.pointee.slotCount {
                let slot = context.pointee.slots + slotIndex
                slotIndex += 1

                let channels = slot.pointee.channelCount
                guard slot.pointee.bufferIndex < inputs.count,
                      let data = inputs[slot.pointee.bufferIndex].mData,
                      Int(inputs[slot.pointee.bufferIndex].mNumberChannels) == channels,
                      Int(inputs[slot.pointee.bufferIndex].mDataByteSize) >= (start + count) * channels * sampleSize
                else {
                    mismatched = true
                    continue
                }
                let source = data.assumingMemoryBound(to: Float32.self) + start * channels

                // De-interleave into the work buffers, noting whether the tap
                // carried anything at all. Negative zero counts as silence.
                var bits: UInt32 = 0
                var peak: Float32 = 0
                frame = 0
                if channels >= 2 {
                    while frame < count {
                        let left = source[frame * channels]
                        let right = source[frame * channels + 1]
                        bits |= left.bitPattern | right.bitPattern
                        peak = max(peak, max(abs(left), abs(right)))
                        scratchLeft[frame] = BiquadScalar(left)
                        scratchRight[frame] = BiquadScalar(right)
                        frame += 1
                    }
                } else {
                    while frame < count {
                        let sample = source[frame]
                        bits |= sample.bitPattern
                        peak = max(peak, abs(sample))
                        scratchLeft[frame] = BiquadScalar(sample)
                        scratchRight[frame] = BiquadScalar(sample)
                        frame += 1
                    }
                }

                if bits & 0x7FFF_FFFF == 0 {
                    tapeq_atomic_u64_add(slot.pointee.silentFrames, UInt64(count))
                    tapeq_atomic_u64_add(slot.pointee.totalSilentFrames, UInt64(count))
                    if tapeq_atomic_u32_load(slot.pointee.hasCarriedAudio) == 0 {
                        tapeq_atomic_u64_add(slot.pointee.framesBeforeAudio, UInt64(count))
                    }
                } else {
                    tapeq_atomic_u64_store(slot.pointee.silentFrames, 0)
                    if tapeq_atomic_u32_load(slot.pointee.hasCarriedAudio) == 0 {
                        // Once per tap: how far into this block the audio
                        // started, so the lead-in is known to the frame.
                        var leading = 0
                        while leading < count, scratchLeft[leading] == 0, scratchRight[leading] == 0 {
                            leading += 1
                        }
                        tapeq_atomic_u64_add(slot.pointee.framesBeforeAudio, UInt64(leading))
                    }
                    tapeq_atomic_u32_store(slot.pointee.hasCarriedAudio, 1)
                    // Single writer: a plain read-compare-write is enough.
                    if peak > Float32(bitPattern: tapeq_atomic_u32_load(slot.pointee.inputPeak)) {
                        tapeq_atomic_u32_store(slot.pointee.inputPeak, peak.bitPattern)
                    }
                }

                guard writesOutput else { continue }
                EQKernel.process(slot.pointee.kernel, left: scratchLeft, right: scratchRight, count: count)
                frame = 0
                while frame < count {
                    mixLeft[frame] += scratchLeft[frame]
                    mixRight[frame] += scratchRight[frame]
                    frame += 1
                }
            }

            if writesOutput, let leftOut {
                let target: BiquadScalar = tapeq_atomic_u32_load(context.pointee.fadeTarget) == 0 ? 0 : 1
                let step = context.pointee.fadeStep
                var gain = context.pointee.fadeGain
                frame = 0
                while frame < count {
                    if gain < target {
                        gain = min(target, gain + step)
                    } else if gain > target {
                        gain = max(target, gain - step)
                    }
                    let left = SoftClipper.clip(mixLeft[frame] * gain)
                    let right = SoftClipper.clip(mixRight[frame] * gain)
                    outputPeak = max(outputPeak, max(abs(left), abs(right)))
                    let position = start + frame
                    if let rightOut {
                        leftOut[position * leftStride] = Float32(left)
                        rightOut[position * rightStride] = Float32(right)
                    } else {
                        // A mono device gets the average of both channels.
                        leftOut[position * leftStride] = Float32((left + right) * 0.5)
                    }
                    frame += 1
                }
                context.pointee.fadeGain = gain
            }

            start += count
        }

        if mismatched {
            tapeq_atomic_u64_add(context.pointee.layoutMismatches, 1)
        }
        let peak = Float32(outputPeak)
        if peak > Float32(bitPattern: tapeq_atomic_u32_load(context.pointee.outputPeak)) {
            tapeq_atomic_u32_store(context.pointee.outputPeak, peak.bitPattern)
        }
    }
}

/// Owns the memory behind a `RenderContext`. Create it before the IOProc
/// starts and release it only after the IOProc can no longer run.
final class RenderMemory {
    /// How long the output takes to fade in after start and out before stop.
    static let fadeDuration = 0.008
    /// Frames each work buffer holds. Larger device buffers are processed in
    /// several passes.
    static let scratchCapacity = 4_096

    let context: UnsafeMutablePointer<RenderContext>
    let slotCount: Int

    /// - Parameter slots: One entry per tap: its kernel and where its buffer
    ///   sits in the IOProc's input list.
    ///   - startsAudible: Whether the output fades in as soon as audio
    ///     starts. Pass false to stay silent until `setAudible(true)`.
    init(
        slots: [(kernel: UnsafeMutablePointer<EQKernel>, bufferIndex: Int, channelCount: Int)],
        sampleRate: Double,
        startsAudible: Bool
    ) {
        slotCount = slots.count
        let slotMemory = UnsafeMutablePointer<TapRenderSlot>.allocate(capacity: max(1, slots.count))
        for (index, slot) in slots.enumerated() {
            (slotMemory + index).initialize(to: TapRenderSlot(
                kernel: slot.kernel,
                bufferIndex: slot.bufferIndex,
                channelCount: slot.channelCount,
                silentFrames: Self.cell(tapeq_atomic_u64()),
                hasCarriedAudio: Self.cell(tapeq_atomic_u32()),
                framesBeforeAudio: Self.cell(tapeq_atomic_u64()),
                totalSilentFrames: Self.cell(tapeq_atomic_u64()),
                inputPeak: Self.cell(tapeq_atomic_u32())
            ))
        }

        let fadeTarget = Self.cell(tapeq_atomic_u32())
        tapeq_atomic_u32_store(fadeTarget, startsAudible ? 1 : 0)

        context = UnsafeMutablePointer<RenderContext>.allocate(capacity: 1)
        context.initialize(to: RenderContext(
            slots: slotMemory,
            slotCount: slots.count,
            scratchLeft: Self.buffer(),
            scratchRight: Self.buffer(),
            mixLeft: Self.buffer(),
            mixRight: Self.buffer(),
            capacity: Self.scratchCapacity,
            callbackCount: Self.cell(tapeq_atomic_u64()),
            layoutMismatches: Self.cell(tapeq_atomic_u64()),
            outputPeak: Self.cell(tapeq_atomic_u32()),
            throughputFrames: Self.cell(tapeq_atomic_u64()),
            fadeTarget: fadeTarget,
            fadeStep: BiquadScalar(1 / max(1, sampleRate * Self.fadeDuration))
        ))
    }

    deinit {
        let value = context.pointee
        for index in 0..<slotCount {
            let slot = value.slots[index]
            slot.silentFrames.deallocate()
            slot.hasCarriedAudio.deallocate()
            slot.framesBeforeAudio.deallocate()
            slot.totalSilentFrames.deallocate()
            slot.inputPeak.deallocate()
        }
        value.slots.deallocate()
        value.scratchLeft.deallocate()
        value.scratchRight.deallocate()
        value.mixLeft.deallocate()
        value.mixRight.deallocate()
        value.callbackCount.deallocate()
        value.layoutMismatches.deallocate()
        value.outputPeak.deallocate()
        value.throughputFrames.deallocate()
        value.fadeTarget.deallocate()
        context.deallocate()
    }

    // MARK: Control-side accessors

    var callbackCount: UInt64 { tapeq_atomic_u64_load(context.pointee.callbackCount) }
    var layoutMismatches: UInt64 { tapeq_atomic_u64_load(context.pointee.layoutMismatches) }

    /// Delay between a tap and the device in the latest callback, in frames.
    var throughputFrames: UInt64 { tapeq_atomic_u64_load(context.pointee.throughputFrames) }

    /// Fades the output in or out. The fade takes `fadeDuration`.
    func setAudible(_ audible: Bool) {
        tapeq_atomic_u32_store(context.pointee.fadeTarget, audible ? 1 : 0)
    }

    /// Frames a tap has delivered in all-zero blocks since the graph started.
    func totalSilentFrames(slot: Int) -> UInt64 {
        tapeq_atomic_u64_load(context.pointee.slots[slot].totalSilentFrames)
    }

    /// Frames a tap delivered before its first non-zero sample.
    func framesBeforeAudio(slot: Int) -> UInt64 {
        tapeq_atomic_u64_load(context.pointee.slots[slot].framesBeforeAudio)
    }

    /// Largest output magnitude since the peaks were last reset.
    var outputPeak: Float {
        Float(bitPattern: tapeq_atomic_u32_load(context.pointee.outputPeak))
    }

    /// Largest input magnitude of a tap since the peaks were last reset.
    func inputPeak(slot: Int) -> Float {
        Float(bitPattern: tapeq_atomic_u32_load(context.pointee.slots[slot].inputPeak))
    }

    /// Starts a new measuring interval for every peak.
    func resetPeaks() {
        tapeq_atomic_u32_store(context.pointee.outputPeak, 0)
        for index in 0..<slotCount {
            tapeq_atomic_u32_store(context.pointee.slots[index].inputPeak, 0)
        }
    }

    /// Frames a tap has delivered since it last carried a non-zero sample.
    func silentFrames(slot: Int) -> UInt64 {
        tapeq_atomic_u64_load(context.pointee.slots[slot].silentFrames)
    }

    /// Whether a tap has ever carried a non-zero sample.
    func hasCarriedAudio(slot: Int) -> Bool {
        tapeq_atomic_u32_load(context.pointee.slots[slot].hasCarriedAudio) != 0
    }

    private static func cell<Cell>(_ initial: Cell) -> UnsafeMutablePointer<Cell> {
        let pointer = UnsafeMutablePointer<Cell>.allocate(capacity: 1)
        pointer.initialize(to: initial)
        return pointer
    }

    private static func buffer() -> UnsafeMutablePointer<BiquadScalar> {
        let pointer = UnsafeMutablePointer<BiquadScalar>.allocate(capacity: scratchCapacity)
        pointer.initialize(repeating: 0, count: scratchCapacity)
        return pointer
    }
}
