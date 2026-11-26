//
//  TapGraph.swift
//  TapEQ
//
//  One running audio graph: a set of process taps, the private aggregate
//  device that carries them, and the IOProc that reads the taps and writes
//  the equalized mix to the real output device.
//
//  A graph is immutable in shape. To change which processes are tapped or
//  which device is used, tear the graph down and build a new one.
//

import CoreAudio
import Foundation

/// What one tap captures.
enum TapScope: Equatable, Sendable {
    /// A stereo mixdown of exactly these process objects.
    case processes([AudioObjectID])
    /// A stereo mixdown of every process except these.
    case everythingExcept([AudioObjectID])
}

/// One tap and the preset that is applied to it.
struct TapPlan: Equatable, Sendable {
    let presetID: UUID
    let scope: TapScope
}

/// The shape of a graph. Two equal plans need no rebuild.
struct GraphPlan: Equatable, Sendable {
    let deviceID: AudioObjectID
    let deviceUID: String
    let taps: [TapPlan]
    /// Frames of the aggregate's latency compensation to cancel on every
    /// tap, or 0 to leave the compensation alone. See `TapGraph.Mode` and
    /// the README section on Bluetooth latency before using this: a value
    /// larger than what the system actually compensates crashes the audio
    /// server.
    var latencyTrimFrames = 0
}

/// What the control side can observe about one tap of a running graph.
struct TapStatus: Sendable {
    let tapID: AudioObjectID
    let plan: TapPlan
    /// Seconds since the tap last carried a non-zero sample.
    let silentSeconds: Double
    let hasCarriedAudio: Bool
    /// Seconds of silence the tap delivered before its first audio.
    let secondsBeforeAudio: Double
    /// Seconds of silence the tap has delivered in total.
    let totalSilentSeconds: Double
    /// Largest input magnitude since the peaks were last reset.
    let inputPeak: Float
}

final class TapGraph {
    private struct Tap {
        let id: AudioObjectID
        let uid: String
        var plan: TapPlan
        /// Kept so the live tap can be modified in place.
        let description: CATapDescription
    }

    let plan: GraphPlan
    private(set) var sampleRate: Double = 0
    private(set) var bufferFrameSize: UInt32 = 0
    private(set) var aggregateID = AudioObjectID.unknown
    let aggregateUID: String
    /// Channels per buffer on each side of the aggregate, for diagnostics.
    private(set) var inputLayout: [Int] = []
    private(set) var outputLayout: [Int] = []
    /// Wall-clock time spent building the graph, in seconds.
    private(set) var buildDuration: Double = 0
    /// Milliseconds spent in each build phase, for diagnostics.
    private(set) var buildTimings: [(phase: String, milliseconds: Double)] = []

    /// Every tap created so far. Filled one by one during the build so a
    /// failure part-way through still knows what to destroy.
    private var taps: [Tap] = []
    /// One EQ chain per tap, in the same order, once the sample rate is known.
    private var processors: [EQProcessor] = []
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var memory: RenderMemory?
    private let log: (String) -> Void

    static let aggregateName = "TapEQ Output"
    static let aggregateUIDPrefix = "pl.bartekk.TapEQ.aggregate."

    var tapIDs: [AudioObjectID] { taps.map(\.id) }

    /// The plan as it stands now, including process lists changed in place.
    var currentPlan: GraphPlan {
        GraphPlan(
            deviceID: plan.deviceID,
            deviceUID: plan.deviceUID,
            taps: taps.map(\.plan),
            latencyTrimFrames: plan.latencyTrimFrames
        )
    }
    var isRunning: Bool { isStarted }

    enum Mode: Equatable, Sendable {
        /// Taps do not mute and the graph plays nothing. Used to find out
        /// whether audio capture is permitted before anything is muted.
        case probe
        /// Taps mute and the graph plays nothing yet. Only for a graph that
        /// is about to replace another one which is still playing the same
        /// processes; call `becomeAudible()` to take over.
        case standby
        /// Taps mute and the graph plays their equalized audio.
        case audible
    }

    let mode: Mode

    /// Whether this graph is the one being heard.
    private(set) var isAudible: Bool

    /// Builds the graph and starts audio. If any step fails, everything
    /// created so far is destroyed before the error is thrown, so a failed
    /// build never leaves a muting tap behind.
    init(plan: GraphPlan, presets: [UUID: Preset], mode: Mode, log: @escaping (String) -> Void) throws {
        self.plan = plan
        self.log = log
        self.mode = mode
        isAudible = mode == .audible
        aggregateUID = Self.aggregateUIDPrefix + UUID().uuidString
        let started = DispatchTime.now()
        do {
            try build(presets: presets)
        } catch {
            log("Graph build failed: \(error)")
            tearDown(graceful: false)
            throw error
        }
        buildDuration = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
    }

    deinit {
        tearDown(graceful: false)
    }

    // MARK: Build

    private func build(presets: [UUID: Preset]) throws {
        guard !plan.taps.isEmpty else {
            throw CoreAudioError(status: kAudioHardwareIllegalOperationError, operation: "Building a graph with no taps")
        }
        var phaseStart = DispatchTime.now()
        func endPhase(_ name: String) {
            let now = DispatchTime.now()
            buildTimings.append((name, Double(now.uptimeNanoseconds - phaseStart.uptimeNanoseconds) / 1e6))
            phaseStart = now
        }

        // 1. Taps.
        for (index, tapPlan) in plan.taps.enumerated() {
            let description: CATapDescription
            switch tapPlan.scope {
            case .processes(let objectIDs):
                description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
            case .everythingExcept(let objectIDs):
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: objectIDs)
            }
            let uuid = UUID()
            description.uuid = uuid
            description.name = "TapEQ tap \(index + 1)"
            description.isPrivate = true
            description.muteBehavior = mode == .probe ? .unmuted : .mutedWhenTapped

            var tapID = AudioObjectID.unknown
            try checkStatus(AudioHardwareCreateProcessTap(description, &tapID), "Creating tap \(index + 1)")
            guard tapID.isValid else {
                throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Creating tap \(index + 1)")
            }
            taps.append(Tap(id: tapID, uid: uuid.uuidString, plan: tapPlan, description: description))
        }
        endPhase("taps")

        // 2. Aggregate device: the real output as the clock and only
        //    sub-device, plus every tap, private to this process.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: plan.deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: plan.deviceUID],
            ],
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                var entry: [String: Any] = [
                    kAudioSubTapUIDKey: tap.uid,
                    kAudioSubTapDriftCompensationKey: true,
                ]
                if plan.latencyTrimFrames > 0 {
                    entry[kAudioSubTapExtraInputLatencyKey] = -plan.latencyTrimFrames
                }
                return entry
            },
        ]
        var newAggregateID = AudioObjectID.unknown
        try checkStatus(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
            "Creating the aggregate device"
        )
        aggregateID = newAggregateID
        endPhase("aggregate")

        // 3. Formats and buffer layout.
        for tap in taps {
            let format = try tap.id.read(
                kAudioTapPropertyFormat,
                as: AudioStreamBasicDescription.self,
                initial: AudioStreamBasicDescription()
            )
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32,
                  (1...2).contains(format.mChannelsPerFrame)
            else {
                throw CoreAudioError(
                    status: kAudioDeviceUnsupportedFormatError,
                    operation: "Using tap format (\(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel) bit, flags \(format.mFormatFlags))"
                )
            }
        }

        try waitForLayout(tapCount: taps.count)
        sampleRate = try aggregateID.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self, initial: 0)
        guard sampleRate > 0 else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "Reading the aggregate sample rate")
        }
        bufferFrameSize = (try? aggregateID.read(kAudioDevicePropertyBufferFrameSize, as: UInt32.self, initial: 0)) ?? 0
        endPhase("layout")

        // 4. Kernels and render memory. The taps occupy the last buffers of
        //    the aggregate's input, in tap-list order; anything before them
        //    is an input stream of the output device itself.
        let firstTapBuffer = inputLayout.count - taps.count
        processors = taps.map { tap in
            let processor = EQProcessor(sampleRate: sampleRate)
            let preset = presets[tap.plan.presetID] ?? BuiltInPresets.flat
            processor.update(bands: preset.bands, preampDB: preset.preampDB)
            return processor
        }
        let renderMemory = RenderMemory(
            slots: processors.enumerated().map { index, processor in
                (processor.kernel, firstTapBuffer + index, inputLayout[firstTapBuffer + index])
            },
            sampleRate: sampleRate,
            startsAudible: mode == .audible
        )
        memory = renderMemory

        // 5. IOProc. A nil queue means the block runs directly on the
        //    device's real-time IO thread. The block captures one raw
        //    pointer and nothing else.
        let context = renderMemory.context
        var procID: AudioDeviceIOProcID?
        try checkStatus(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, output, outputTime in
                RenderContext.render(context, input: input, inputTime: inputTime, output: output, outputTime: outputTime)
            },
            "Creating the IOProc"
        )
        ioProcID = procID

        if firstTapBuffer > 0 {
            disableLeadingInputStreams(count: firstTapBuffer, total: inputLayout.count)
        }

        endPhase("ioproc")
        try checkStatus(AudioDeviceStart(aggregateID, procID), "Starting the aggregate device")
        isStarted = true
        endPhase("start")
    }

    /// Reads the aggregate's buffer layout, waiting briefly for the tap
    /// streams to appear: they are attached a moment after the device is
    /// created.
    private func waitForLayout(tapCount: Int) throws {
        let deadline = DispatchTime.now() + .milliseconds(400)
        while true {
            inputLayout = (try? aggregateID.channelLayout(scope: kAudioObjectPropertyScopeInput)) ?? []
            outputLayout = (try? aggregateID.channelLayout(scope: kAudioObjectPropertyScopeOutput)) ?? []
            let tapBuffers = inputLayout.suffix(tapCount)
            let ready = inputLayout.count >= tapCount
                && tapBuffers.allSatisfy { (1...2).contains($0) }
                && !outputLayout.isEmpty
                && outputLayout[0] > 0
            if ready { return }
            if DispatchTime.now() >= deadline { break }
            usleep(5_000)
        }
        throw CoreAudioError(
            status: kAudioHardwareUnspecifiedError,
            operation: "Waiting for the aggregate layout (input \(inputLayout), output \(outputLayout), \(tapCount) taps)"
        )
    }

    /// When the output device also has inputs (a USB headset, for example)
    /// its input streams show up ahead of the taps. This IOProc has no use
    /// for them, so tell the HAL not to run them on its behalf.
    private func disableLeadingInputStreams(count: Int, total: Int) {
        guard let ioProcID else { return }
        let headerSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = headerSize + total * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        raw.storeBytes(of: unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(total), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for index in 0..<total {
            raw.storeBytes(
                of: UInt32(index < count ? 0 : 1),
                toByteOffset: headerSize + index * MemoryLayout<UInt32>.size,
                as: UInt32.self
            )
        }
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
        if status != noErr {
            log("Could not switch off \(count) device input stream(s): \(CoreAudioError.describe(status))")
        }
    }

    // MARK: Teardown

    /// Stops audio and destroys everything, in the order the HAL needs:
    /// stop IO, destroy the IOProc, destroy the aggregate, destroy the taps.
    /// Safe to call more than once.
    ///
    /// - Parameter graceful: Fade the output out first. Use it for planned
    ///   rebuilds; skip it when the device is already gone or misbehaving.
    func tearDown(graceful: Bool) {
        if graceful, isStarted, isAudible, let memory {
            let before = memory.callbackCount
            memory.setAudible(false)
            usleep(useconds_t((RenderMemory.fadeDuration + 0.004) * 1_000_000))
            if memory.callbackCount == before {
                log("IOProc was not running during fade-out")
            }
        }

        if let ioProcID, aggregateID.isValid {
            if isStarted {
                let status = AudioDeviceStop(aggregateID, ioProcID)
                if status != noErr { log("AudioDeviceStop: \(CoreAudioError.describe(status))") }
                isStarted = false
            }
            let status = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            if status != noErr { log("AudioDeviceDestroyIOProcID: \(CoreAudioError.describe(status))") }
        }
        ioProcID = nil
        isStarted = false

        if aggregateID.isValid {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { log("AudioHardwareDestroyAggregateDevice: \(CoreAudioError.describe(status))") }
            aggregateID = .unknown
        }

        for tap in taps {
            let status = AudioHardwareDestroyProcessTap(tap.id)
            if status != noErr { log("AudioHardwareDestroyProcessTap(\(tap.id)): \(CoreAudioError.describe(status))") }
        }

        // The IOProc is gone, but give a callback that was already in flight
        // time to return before its memory is released.
        let retiredProcessors = processors
        let retiredMemory = memory
        taps = []
        processors = []
        memory = nil
        if retiredMemory != nil || !retiredProcessors.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                _ = retiredProcessors
                _ = retiredMemory
            }
        }
    }

    // MARK: Live changes

    /// Fades a standby graph in. The graph it replaces should be torn down
    /// (with a fade-out) right after, so the two cross over.
    func becomeAudible() {
        guard mode != .probe else { return }
        memory?.setAudible(true)
        isAudible = true
    }

    /// Changes which processes a tap captures without rebuilding the graph.
    /// The tap keeps its kind: a process tap stays a process tap.
    @discardableResult
    func updateScope(ofTap index: Int, to scope: TapScope) -> Bool {
        guard taps.indices.contains(index) else { return false }
        switch (taps[index].plan.scope, scope) {
        case (.processes, .processes(let objectIDs)), (.everythingExcept, .everythingExcept(let objectIDs)):
            taps[index].description.processes = objectIDs
        default:
            return false
        }
        guard apply(taps[index].description, to: taps[index].id, what: "process list") else { return false }
        taps[index].plan = TapPlan(presetID: taps[index].plan.presetID, scope: scope)
        return true
    }

    /// Pushes a modified description to a live tap.
    private func apply(_ description: CATapDescription, to tapID: AudioObjectID, what: String) -> Bool {
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var reference = description
        let status = withUnsafeMutablePointer(to: &reference) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        if status != noErr {
            log("Changing \(what) of tap \(tapID) in place failed: \(CoreAudioError.describe(status))")
        }
        return status == noErr
    }

    /// Applies an edited preset to every tap that uses it, without a rebuild.
    /// Applies an edited preset to every tap that uses it, without a rebuild.
    func update(preset: Preset) {
        for (tap, processor) in zip(taps, processors) where tap.plan.presetID == preset.id {
            processor.update(bands: preset.bands, preampDB: preset.preampDB)
        }
    }

    /// Frees coefficient sets the audio thread has finished with.
    func collectGarbage() {
        for processor in processors {
            processor.collectGarbage()
        }
    }

    /// Number of IOProc calls so far. Stops advancing when audio stalls.
    var callbackCount: UInt64 { memory?.callbackCount ?? 0 }

    var layoutMismatches: UInt64 { memory?.layoutMismatches ?? 0 }

    /// Delay the graph adds between a tap and the device, in seconds.
    var addedLatency: Double {
        guard let memory, sampleRate > 0 else { return 0 }
        return Double(memory.throughputFrames) / sampleRate
    }

    /// Largest output magnitude since the peaks were last reset.
    var outputPeak: Float { memory?.outputPeak ?? 0 }

    /// Starts a new measuring interval for the input and output peaks.
    func resetPeaks() { memory?.resetPeaks() }

    func tapStatuses() -> [TapStatus] {
        guard let memory, sampleRate > 0 else { return [] }
        return taps.enumerated().map { index, tap in
            TapStatus(
                tapID: tap.id,
                plan: tap.plan,
                silentSeconds: Double(memory.silentFrames(slot: index)) / sampleRate,
                hasCarriedAudio: memory.hasCarriedAudio(slot: index),
                secondsBeforeAudio: Double(memory.framesBeforeAudio(slot: index)) / sampleRate,
                totalSilentSeconds: Double(memory.totalSilentFrames(slot: index)) / sampleRate,
                inputPeak: memory.inputPeak(slot: index)
            )
        }
    }
}
