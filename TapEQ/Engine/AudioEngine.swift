//
//  AudioEngine.swift
//  TapEQ
//
//  Keeps the audio graph in step with the rules, the overrides, the playing
//  processes and the output device.
//
//  How a change reaches the speakers
//  ---------------------------------
//  Every event that could matter (a process starts playing, a rule changes,
//  the output device switches) ends in `reconcile()`, which computes the plan
//  the graph should have and compares it with what is running:
//
//  • Same taps, same processes: nothing to do.
//  • Same taps, different processes: the live taps are edited in place.
//  • Different taps: a second graph is built in standby next to the running
//    one. It reads its taps but stays silent until they are delivering
//    audio; then the two graphs cross over and the old one is destroyed.
//  • No graph yet: one is built and starts playing at once.
//
//  The engine fails open. Processes are only muted by taps that a running
//  IOProc is reading, and a graph that is not being heard is never left
//  muting on its own. If a build fails, the device changes under the graph,
//  the audio server restarts or the IOProc stops being called, every tap is
//  destroyed first and rebuilt afterwards, so the worst outcome is audio
//  without EQ, never silence.
//

import AppKit
import CoreAudio
import Foundation
import Observation
import os

/// What is known about the audio capture permission. There is no public API
/// to query it, so it is inferred: capture is permitted once a tap has
/// delivered real audio.
enum CapturePermission: Equatable, Sendable {
    /// No tap has delivered audio yet since launch.
    case unknown
    /// A tap delivered audio.
    case granted
    /// Apps are playing but the taps deliver only silence, which is what a
    /// denied permission looks like.
    case suspectedDenied
}

/// An app that is playing audio right now.
struct PlayingApp: Identifiable, Equatable, Sendable {
    /// The identifier the app is overridden and matched under.
    let id: String
    let name: String
    let bundleURL: URL?
    let note: String?
    let resolution: Resolution
    /// True when the app plays to a device other than the default output,
    /// which this version leaves alone.
    let isOnOtherDevice: Bool
    /// The identifiers rules are matched against: the app's own and, for a
    /// helper, those of the app it belongs to.
    var matchIDs: [String] = []
}

/// Everything the engine needs to know from the model.
struct EngineConfiguration: Equatable, Sendable {
    var context = ResolutionContext()
    var presets: [UUID: Preset] = [:]
    /// Cancel the latency compensation of taps on Bluetooth outputs.
    var trimsBluetoothLatency = false
    /// Devices on which the trim went wrong once and is not tried again.
    var latencyTrimDisabledDeviceUIDs: Set<String> = []
}

/// A snapshot of the engine's internals for the diagnostics view.
struct EngineDiagnostics: Equatable, Sendable {
    struct Tap: Equatable, Identifiable, Sendable {
        let id: AudioObjectID
        let presetName: String
        let scope: String
        let silentSeconds: Double
        let hasCarriedAudio: Bool
        let inputPeak: Float
    }

    var aggregateID: AudioObjectID?
    var aggregateUID: String?
    var sampleRate: Double = 0
    var bufferFrameSize: UInt32 = 0
    /// Delay between a tap and the device inside the graph, in seconds.
    var graphLatency: Double = 0
    /// Delay the system adds to tap audio on this device, in seconds.
    var tapLatency: Double = 0
    var latencyTrimFrames = 0
    var inputLayout: [Int] = []
    var outputLayout: [Int] = []
    var mode = ""
    var hasStandbyGraph = false
    var taps: [Tap] = []
    var outputPeak: Float = 0
    var layoutMismatches: UInt64 = 0
    var lastBuild: String = ""
}

@MainActor
@Observable
final class AudioEngine {
    enum Phase: Equatable, Sendable {
        case stopped
        /// Nothing that plays needs equalizing.
        case idle
        case bypassed
        case noOutputDevice
        /// Listening without muting, waiting for proof that capture works.
        case checkingPermission
        /// A graph is equalizing audio.
        case active
        /// The last build failed; a retry is scheduled.
        case failed(String)

        var displayName: String {
            switch self {
            case .stopped: return "Stopped"
            case .idle: return "Idle (nothing to equalize)"
            case .bypassed: return "Bypassed"
            case .noOutputDevice: return "No output device"
            case .checkingPermission: return "Waiting for audio"
            case .active: return "Active"
            case .failed(let message): return "Failed: \(message)"
            }
        }
    }

    // MARK: Observable state

    private(set) var phase: Phase = .stopped
    private(set) var currentDevice: OutputDevice?
    private(set) var devices: [OutputDevice] = []
    /// The effective device-level preset for the current output.
    private(set) var deviceResolution: Resolution = .unmatched
    private(set) var playingApps: [PlayingApp] = []
    private(set) var permission: CapturePermission = .unknown
    private(set) var diagnostics = EngineDiagnostics()
    /// The most recent log lines, oldest first.
    private(set) var logLines: [String] = []
    private(set) var watchdogEvents: [String] = []

    // MARK: Callbacks to the model

    /// The default output device changed. Called before the engine reacts.
    @ObservationIgnored var onDefaultOutputChanged: ((OutputDevice?) -> Void)?
    /// The list of connected output devices changed.
    @ObservationIgnored var onDevicesChanged: (([OutputDevice]) -> Void)?
    /// The latency trim misbehaved on this device and must stay off for it.
    @ObservationIgnored var onLatencyTrimFailed: ((OutputDevice) -> Void)?

    // MARK: Tuning

    private enum Timing {
        /// Minimum spacing between reconciliations triggered by events.
        static let debounce = 0.2
        /// How long a standby graph runs, on top of the tap latency of the
        /// device, before it takes over.
        static let standbyMargin = 0.12
        /// A standby graph takes over this long after it could have, even
        /// if its taps have not carried audio yet.
        static let standbyTimeout = 1.0
        /// How often the housekeeping timer runs while a graph exists.
        static let tick = 0.25
        /// Ticks without an IOProc call before the graph is declared dead.
        static let stalledTicks = 3
        /// How long the graph is kept after the last stream stops, so the
        /// gap between two songs does not cost a rebuild.
        static let idleLinger = 5.0
        /// Silence from a tap whose process claims to be playing, before the
        /// watchdog rebuilds.
        static let watchdogSilence = 3.0
        static let watchdogInterval = 30.0
        /// Silence from every tap while apps play, before the permission is
        /// reported as probably denied.
        static let permissionDoubt = 3.0
        /// A graph with a latency trim that dies this soon after it was
        /// built is taken as evidence against the trim.
        static let trimProbation = 20.0
        static let maxLogLines = 100
        static let maxWatchdogEvents = 20
    }

    // MARK: Private state

    @ObservationIgnored private var processMonitor = ProcessMonitor()
    @ObservationIgnored private var deviceMonitor = DeviceMonitor()
    @ObservationIgnored private let identities = AppIdentityResolver()
    @ObservationIgnored private var configuration = EngineConfiguration()

    /// The graph that is being heard.
    @ObservationIgnored private var graph: TapGraph?
    /// A probe or standby graph waiting for its moment.
    @ObservationIgnored private var pending: TapGraph?
    @ObservationIgnored private var pendingSince: TimeInterval = 0
    /// The device format the graphs were built for.
    @ObservationIgnored private var graphFormat: DeviceFormat?

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var reconcileScheduled = false
    @ObservationIgnored private var lastReconcile: TimeInterval = 0
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var notNeededSince: TimeInterval?
    @ObservationIgnored private var isNeeded = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var retryAfter: TimeInterval = 0

    @ObservationIgnored private var lastCallbackCount: UInt64 = 0
    @ObservationIgnored private var stalledTicks = 0
    @ObservationIgnored private var lastPendingCallbackCount: UInt64 = 0
    @ObservationIgnored private var pendingStalledTicks = 0
    @ObservationIgnored private var ticksSincePeakReset = 0
    @ObservationIgnored private var ticksSinceStatsLine = 0

    @ObservationIgnored private var lastWatchdog: TimeInterval = -1_000
    /// Taps the watchdog has already rebuilt for and that have stayed silent
    /// since. They are left alone until they carry audio again.
    @ObservationIgnored private var quietTaps: Set<String> = []
    /// When each tap was first seen silent while one of its processes was
    /// playing.
    @ObservationIgnored private var suspectSince: [AudioObjectID: TimeInterval] = [:]

    /// When a graph with a latency trim was last built, and on which device.
    @ObservationIgnored private var lastTrimmedBuild: (time: TimeInterval, device: OutputDevice)?
    /// Devices the trim failed on since launch. The model is told as well
    /// and remembers them for good.
    @ObservationIgnored private var trimFailedDeviceUIDs: Set<String> = []

    @ObservationIgnored private var serviceRestartListener: AudioPropertyListener?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let logger = Logger(subsystem: "pl.bartekk.TapEQ", category: "engine")
    @ObservationIgnored private let logFile: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["TAPEQ_LOG_FILE"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    @ObservationIgnored private let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        log("Engine starting")

        startMonitors()
        serviceRestartListener = AudioPropertyListener(
            object: .system,
            selector: kAudioHardwarePropertyServiceRestarted
        ) { [weak self] in
            self?.audioServerRestarted()
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tearDownAll(reason: "system is going to sleep", graceful: false)
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deviceMonitor.refresh()
                self?.processMonitor.refresh()
                self?.scheduleReconcile()
            }
        })

        onDevicesChanged?(deviceMonitor.outputDevices)
        onDefaultOutputChanged?(deviceMonitor.defaultOutput)
        reconcile()
    }

    private func startMonitors() {
        processMonitor.onChange = { [weak self] in self?.scheduleReconcile() }
        deviceMonitor.onDevicesChanged = { [weak self] in
            guard let self else { return }
            onDevicesChanged?(deviceMonitor.outputDevices)
            scheduleReconcile()
        }
        deviceMonitor.onDefaultOutputChanged = { [weak self] in
            guard let self else { return }
            let device = deviceMonitor.defaultOutput
            log("Default output is now \(device.map { "\($0.name) [\($0.uid)]" } ?? "none")")
            // A graph on the old device is useless and its taps would keep
            // muting; get rid of it before anything else. Losing the output
            // altogether is what an audio server crash looks like from
            // here; a switch to another device is just the user's choice.
            if device == nil { graphEndedUnexpectedly() }
            tearDownAll(reason: "output device changed", graceful: false)
            onDefaultOutputChanged?(device)
            reconcile()
        }
        deviceMonitor.onDefaultFormatChanged = { [weak self] in
            guard let self else { return }
            let format = deviceMonitor.defaultFormat
            log("Output format changed: \(format.map { "\($0.sampleRate) Hz, layout \($0.outputLayout), latency \($0.outputLatencyFrames) frames" } ?? "unknown")")
            tearDownAll(reason: "output format changed", graceful: false)
            scheduleReconcile()
        }
        deviceMonitor.start()
        processMonitor.start()
    }

    /// Destroys every tap and stops listening. Call before the app exits.
    func stop() {
        guard isStarted else { return }
        tearDownAll(reason: "engine stopping", graceful: true)
        isStarted = false
        tickTimer?.invalidate()
        tickTimer = nil
        processMonitor.stop()
        deviceMonitor.stop()
        serviceRestartListener = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        phase = .stopped
    }

    /// The audio server went away and came back. Every tap, aggregate and
    /// listener this app had is gone with it.
    private func audioServerRestarted() {
        log("The audio server restarted")
        graphEndedUnexpectedly()
        tearDownAll(reason: "audio server restarted", graceful: false)
        processMonitor.stop()
        deviceMonitor.stop()
        processMonitor = ProcessMonitor()
        deviceMonitor = DeviceMonitor()
        startMonitors()
        onDevicesChanged?(deviceMonitor.outputDevices)
        // Give the server a moment to bring its devices back.
        retryAfter = now + 1
        scheduleReconcile(after: 1)
    }

    // MARK: Input from the model

    /// Hands the engine a new set of rules, overrides and presets. Edited
    /// presets reach running taps at once; anything that changes which
    /// process gets which preset goes through a reconciliation.
    func apply(_ newConfiguration: EngineConfiguration) {
        guard newConfiguration != configuration else { return }
        let old = configuration
        configuration = newConfiguration

        for (id, preset) in newConfiguration.presets where old.presets[id] != preset {
            graph?.update(preset: preset)
            pending?.update(preset: preset)
        }

        var routing = old
        routing.presets = newConfiguration.presets
        let routingChanged = routing != newConfiguration
            || Set(old.presets.keys) != Set(newConfiguration.presets.keys)
        if routingChanged, isStarted {
            // A person just changed something and is listening for the
            // result: do not make them wait for the debounce.
            reconcile()
        }
    }

    /// Throws the current graph away and builds a new one.
    func rebuild() {
        log("Manual rebuild requested")
        tearDownAll(reason: "manual rebuild", graceful: true)
        consecutiveFailures = 0
        retryAfter = 0
        reconcile()
    }

    // MARK: Planning

    private struct Desired {
        var plan: GraphPlan?
        /// Whether anything that is playing right now would be equalized.
        var isNeeded = false
    }

    /// A process that is busy on some other device is left alone: tapping it
    /// would pull its audio onto the default output.
    private func isOnOtherDevice(_ process: AudioProcess, device: OutputDevice) -> Bool {
        guard process.isRunningOutput, !device.isAggregate, !process.outputDeviceIDs.isEmpty else { return false }
        var ours: Set<AudioObjectID> = [device.objectID]
        if let id = graph?.aggregateID, id.isValid { ours.insert(id) }
        if let id = pending?.aggregateID, id.isValid { ours.insert(id) }
        return ours.isDisjoint(with: process.outputDeviceIDs)
    }

    /// Frames of tap latency compensation to cancel on `device`, or 0.
    ///
    /// On Bluetooth outputs the system delays tap audio by the latency the
    /// device reports (160 ms on AirPods Max), which then adds to the
    /// device's real latency. Cancelling exactly that amount removes the
    /// delay; cancelling more crashes the audio server, so this is opt-in
    /// and is abandoned for a device at the first sign of trouble.
    private func latencyTrim(for device: OutputDevice) -> Int {
        guard configuration.trimsBluetoothLatency,
              device.isBluetooth,
              !configuration.latencyTrimDisabledDeviceUIDs.contains(device.uid),
              !trimFailedDeviceUIDs.contains(device.uid)
        else { return 0 }
        return max(0, deviceMonitor.defaultFormat?.outputLatencyFrames ?? 0)
    }

    private func computeDesired() -> Desired {
        let context = configuration.context
        guard !context.bypassAll, let device = deviceMonitor.defaultOutput else { return Desired() }

        let ownPID = getpid()
        var excluded: [AudioObjectID] = []
        if let ownObject = AudioObjectID.processObject(forPID: ownPID) {
            excluded.append(ownObject)
        }
        var groups: [UUID: [AudioObjectID]] = [:]
        var isNeeded = false

        for process in processMonitor.processes where process.pid != ownPID {
            if isOnOtherDevice(process, device: device) {
                excluded.append(process.objectID)
                continue
            }
            let identity = identities.identity(for: process)
            let resolution = Resolver.resolve(processBundleIDs: identity.matchIDs, deviceUID: device.uid, in: context)
            if resolution.source.isAppLevel {
                // Decided by the app: its own tap, or no tap at all. Either
                // way it stays out of the device-wide tap. Processes that
                // are not playing yet are included, so that starting to play
                // does not change the shape of the graph.
                excluded.append(process.objectID)
                if let presetID = resolution.presetID {
                    groups[presetID, default: []].append(process.objectID)
                    if process.isRunningOutput { isNeeded = true }
                }
            } else if resolution.presetID != nil, process.isRunningOutput {
                isNeeded = true
            }
        }

        var taps = groups.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { TapPlan(presetID: $0, scope: .processes(groups[$0, default: []].sorted())) }
        if let devicePreset = Resolver.resolveDevice(deviceUID: device.uid, in: context).presetID {
            taps.append(TapPlan(presetID: devicePreset, scope: .everythingExcept(excluded.sorted())))
        }
        guard !taps.isEmpty else { return Desired() }
        return Desired(
            plan: GraphPlan(
                deviceID: device.objectID,
                deviceUID: device.uid,
                taps: taps,
                latencyTrimFrames: latencyTrim(for: device)
            ),
            isNeeded: isNeeded
        )
    }

    /// Whether `plan` can be reached from `current` by editing process lists
    /// alone: same device, same taps of the same kind for the same presets.
    private func sameShape(_ current: GraphPlan, _ plan: GraphPlan) -> Bool {
        guard current.deviceID == plan.deviceID, current.deviceUID == plan.deviceUID,
              current.latencyTrimFrames == plan.latencyTrimFrames,
              current.taps.count == plan.taps.count
        else { return false }
        return zip(current.taps, plan.taps).allSatisfy { old, new in
            guard old.presetID == new.presetID else { return false }
            switch (old.scope, new.scope) {
            case (.processes, .processes), (.everythingExcept, .everythingExcept): return true
            default: return false
            }
        }
    }

    /// Brings a live graph in line with `plan` without rebuilding it, if
    /// that is possible.
    private func bringInLine(_ target: TapGraph, with plan: GraphPlan) -> Bool {
        if target.currentPlan == plan { return true }
        guard sameShape(target.currentPlan, plan) else { return false }
        for (index, tap) in plan.taps.enumerated() where target.currentPlan.taps[index].scope != tap.scope {
            guard target.updateScope(ofTap: index, to: tap.scope) else { return false }
        }
        return true
    }

    // MARK: Reconciliation

    /// Requests a reconciliation, at most one per debounce interval. The
    /// first event after a quiet spell is handled on the next run loop pass.
    func scheduleReconcile(after delay: TimeInterval? = nil) {
        guard isStarted, !reconcileScheduled else { return }
        reconcileScheduled = true
        let wait = delay ?? max(0, Timing.debounce - (now - lastReconcile))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileScheduled = false
                self.reconcile()
            }
        }
    }

    private func reconcile() {
        guard isStarted else { return }
        lastReconcile = now
        identities.prune(keeping: Set(processMonitor.processes.map(\.pid)))
        publishRouting()

        let desired = computeDesired()
        isNeeded = desired.isNeeded

        // A graph built for another device or format is stale. The device
        // callbacks already tear down; this is the backstop.
        if let format = graphFormat, graph != nil || pending != nil, format != deviceMonitor.defaultFormat {
            tearDownAll(reason: "output format no longer matches", graceful: false)
        }

        guard let plan = desired.plan else {
            tearDownAll(reason: "nothing left to equalize", graceful: true)
            notNeededSince = nil
            updatePhase()
            return
        }

        if desired.isNeeded {
            notNeededSince = nil
        } else if notNeededSince == nil {
            notNeededSince = now
        }

        // The graph being heard, if it can be kept.
        if let graph {
            if let since = notNeededSince, now - since >= Timing.idleLinger {
                tearDownAll(reason: "idle", graceful: true)
                updatePhase()
                return
            }
            if bringInLine(graph, with: plan) {
                discardPending(reason: "the running graph already matches")
                updatePhase()
                return
            }
        }

        // A probe or standby graph is only worth keeping while something
        // that needs it is playing.
        if !desired.isNeeded {
            discardPending(reason: "no longer needed")
        }
        if let pending {
            if bringInLine(pending, with: plan) {
                updatePhase()
                return
            }
            discardPending(reason: "the plan changed")
        }

        guard desired.isNeeded else {
            // Nothing that is playing needs this plan, so there is no reason
            // to build it. A running graph that got this far could not be
            // brought in line with the plan, so it cannot stay either.
            tearDownAll(reason: "plan changed while idle", graceful: true)
            updatePhase()
            return
        }

        guard now >= retryAfter else {
            scheduleReconcile(after: retryAfter - now)
            updatePhase()
            return
        }

        if permission != .granted {
            // Until capture is known to work nothing may be muted: a muting
            // tap that delivers nothing would silence the app.
            build(plan, mode: .probe)
        } else if graph == nil {
            build(plan, mode: .audible)
        } else {
            build(plan, mode: .standby)
        }
        updatePhase()
    }

    private func build(_ plan: GraphPlan, mode: TapGraph.Mode) {
        do {
            let newGraph = try TapGraph(plan: plan, presets: configuration.presets, mode: mode) { [weak self] message in
                self?.log(message)
            }
            graphFormat = deviceMonitor.defaultFormat
            if plan.latencyTrimFrames > 0, let device = deviceMonitor.defaultOutput {
                lastTrimmedBuild = (now, device)
            }
            let timings = newGraph.buildTimings.map { String(format: "%@ %.0f ms", $0.phase, $0.milliseconds) }.joined(separator: ", ")
            diagnostics.lastBuild = String(format: "%.0f ms (%@)", newGraph.buildDuration * 1000, timings)
            let trim = plan.latencyTrimFrames > 0 ? ", latency trim \(plan.latencyTrimFrames) frames" : ""
            log("Built \(mode) graph with \(plan.taps.count) tap(s) on \(plan.deviceUID)\(trim) in \(diagnostics.lastBuild): \(describe(plan))")

            switch mode {
            case .audible:
                graph = newGraph
                lastCallbackCount = 0
                stalledTicks = 0
            case .probe, .standby:
                pending = newGraph
                pendingSince = now
                lastPendingCallbackCount = 0
                pendingStalledTicks = 0
                if mode == .standby {
                    DispatchQueue.main.asyncAfter(deadline: .now() + standbyDelay + 0.01) { [weak self] in
                        MainActor.assumeIsolated { self?.checkPending() }
                    }
                }
            }
            startTicking()
        } catch {
            buildFailed("\(error)")
        }
    }

    private func buildFailed(_ message: String) {
        consecutiveFailures += 1
        let delay = min(15, 0.5 * pow(2, Double(consecutiveFailures - 1)))
        retryAfter = now + delay
        log("Could not build the graph (attempt \(consecutiveFailures)): \(message). Retrying in \(String(format: "%.1f", delay)) s")
        if graph == nil {
            phase = .failed(message)
        }
        scheduleReconcile(after: delay)
    }

    /// How long a standby graph needs before its taps carry audio: the
    /// latency the system applies to taps on this device, plus a margin.
    private var standbyDelay: TimeInterval {
        Timing.standbyMargin + tapLatency(of: pending ?? graph)
    }

    /// The delay the system adds to tap audio for a graph on the current
    /// device: the device's reported latency, less whatever the graph trims.
    private func tapLatency(of target: TapGraph?) -> TimeInterval {
        guard let format = deviceMonitor.defaultFormat, format.sampleRate > 0 else { return 0 }
        let trimmed = target?.plan.latencyTrimFrames ?? 0
        return Double(max(0, format.outputLatencyFrames - trimmed)) / format.sampleRate
    }

    /// Moves a probe or standby graph along once it has done its waiting.
    private func checkPending() {
        guard let pending else { return }
        let statuses = pending.tapStatuses()
        let hasCarriedAudio = statuses.contains(where: \.hasCarriedAudio)
        let age = now - pendingSince

        if permission != .granted, hasCarriedAudio {
            permission = .granted
            log("Audio capture is permitted (a tap delivered audio)")
        }

        switch pending.mode {
        case .probe:
            if permission == .granted {
                // The probe has served its purpose. The real graph is built
                // muting from the start.
                discardPending(reason: "capture confirmed")
                reconcile()
            } else if permission == .unknown, age >= Timing.permissionDoubt, isNeeded {
                permission = .suspectedDenied
                log("Taps deliver only silence while apps are playing. Audio capture is probably not permitted; nothing will be muted")
            }

        case .standby:
            guard let old = graph else {
                // The graph it was meant to relieve is gone. A silent graph
                // must not sit there muting.
                promotePending()
                return
            }
            let oldIsCarryingAudio = old.tapStatuses().contains { $0.silentSeconds < Timing.tick }
            let ready = age >= standbyDelay && (hasCarriedAudio || !oldIsCarryingAudio)
            if ready || age >= Timing.standbyTimeout + standbyDelay {
                promotePending()
            }

        case .audible:
            break
        }
        updatePhase()
    }

    /// Crosses over from the running graph to the standby graph.
    private func promotePending() {
        guard let pending, pending.mode == .standby else { return }
        let old = graph
        self.pending = nil
        pending.becomeAudible()
        graph = pending
        lastCallbackCount = pending.callbackCount
        stalledTicks = 0
        // The old graph fades out while the new one fades in.
        old?.tearDown(graceful: true)
        consecutiveFailures = 0
        retryAfter = 0
        quietTaps.removeAll()
        suspectSince.removeAll()
        log("Switched to the new graph\(old == nil ? "" : " (crossed over from the previous one)")")
    }

    private func discardPending(reason: String) {
        guard let pending else { return }
        pending.tearDown(graceful: false)
        self.pending = nil
        log("Discarded the \(pending.mode) graph: \(reason)")
    }

    /// Destroys every graph. This is the fail-open path: after it returns no
    /// tap of this app exists.
    private func tearDownAll(reason: String, graceful: Bool) {
        guard graph != nil || pending != nil else { return }
        // Standby first: it must never be left muting without the graph
        // that is being heard.
        pending?.tearDown(graceful: false)
        pending = nil
        graph?.tearDown(graceful: graceful)
        graph = nil
        graphFormat = nil
        notNeededSince = nil
        quietTaps.removeAll()
        suspectSince.removeAll()
        log("Tore down the graph: \(reason)")
        refreshDiagnostics()
    }

    /// Called when a graph died for a reason other than this engine's own
    /// choice. If it was using a latency trim and had only just been built,
    /// the trim is the prime suspect: stop using it on this device.
    private func graphEndedUnexpectedly() {
        guard let build = lastTrimmedBuild, now - build.time <= Timing.trimProbation else { return }
        guard graph?.plan.latencyTrimFrames ?? 0 > 0 || pending?.plan.latencyTrimFrames ?? 0 > 0 else { return }
        lastTrimmedBuild = nil
        guard trimFailedDeviceUIDs.insert(build.device.uid).inserted else { return }
        log("A graph with a latency trim on \(build.device.name) ended within \(Int(Timing.trimProbation)) s of being built. The trim is now off for this device")
        onLatencyTrimFailed?(build.device)
    }

    // MARK: Housekeeping

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: Timing.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Keep running while a menu or a slider is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard graph != nil || pending != nil else {
            tickTimer?.invalidate()
            tickTimer = nil
            refreshDiagnostics()
            return
        }
        graph?.collectGarbage()
        pending?.collectGarbage()

        checkHeartbeat()
        checkPending()
        checkWatchdog()
        if let since = notNeededSince, now - since >= Timing.idleLinger {
            reconcile()
        }
        refreshDiagnostics()
        writeDevelopmentLog()

        ticksSincePeakReset += 1
        if ticksSincePeakReset >= 4 {
            // Levels are shown as the peak over the last second.
            ticksSincePeakReset = 0
            graph?.resetPeaks()
            pending?.resetPeaks()
        }
    }

    /// An IOProc that is no longer called cannot play the audio its taps are
    /// muting. Destroy the taps at once and start over.
    private func checkHeartbeat() {
        if let graph {
            let count = graph.callbackCount
            if count == lastCallbackCount {
                stalledTicks += 1
                if stalledTicks >= Timing.stalledTicks {
                    log("The IOProc has not run for \(String(format: "%.2f", Double(stalledTicks) * Timing.tick)) s")
                    graphEndedUnexpectedly()
                    tearDownAll(reason: "IOProc stopped", graceful: false)
                    buildFailed("the IOProc stopped running")
                    updatePhase()
                    return
                }
            } else {
                stalledTicks = 0
                lastCallbackCount = count
            }
        }
        if let pending {
            let count = pending.callbackCount
            if count == lastPendingCallbackCount {
                pendingStalledTicks += 1
                if pendingStalledTicks >= Timing.stalledTicks {
                    graphEndedUnexpectedly()
                    discardPending(reason: "its IOProc is not running")
                    buildFailed("the IOProc of the new graph never ran")
                    updatePhase()
                }
            } else {
                pendingStalledTicks = 0
                lastPendingCallbackCount = count
            }
        }
    }

    /// Rebuilds from scratch when a tap stays silent although one of its
    /// processes says it is playing.
    private func checkWatchdog() {
        guard let graph, let device = deviceMonitor.defaultOutput else { return }
        let ownPID = getpid()
        let playing = Set(
            processMonitor.processes
                .filter { $0.isRunningOutput && $0.pid != ownPID && !isOnOtherDevice($0, device: device) }
                .map(\.objectID)
        )

        for status in graph.tapStatuses() {
            let key = quietKey(status.plan)
            let shouldCarryAudio: Bool
            switch status.plan.scope {
            case .processes(let objectIDs): shouldCarryAudio = !playing.isDisjoint(with: objectIDs)
            case .everythingExcept(let objectIDs): shouldCarryAudio = !playing.subtracting(objectIDs).isEmpty
            }
            // The clock runs only while the tap is silent *and* a process in
            // it is playing. A tap that sat idle for a minute is not at
            // fault the moment its app presses play.
            guard shouldCarryAudio, status.silentSeconds >= Timing.tick * 2 else {
                suspectSince[status.tapID] = nil
                if status.silentSeconds < Timing.tick * 2 { quietTaps.remove(key) }
                continue
            }
            let since = suspectSince[status.tapID] ?? now
            suspectSince[status.tapID] = since
            let silentFor = now - since
            guard silentFor >= Timing.watchdogSilence,
                  !quietTaps.contains(key),
                  now - lastWatchdog >= Timing.watchdogInterval
            else { continue }

            lastWatchdog = now
            let event = "\(logTimeFormatter.string(from: Date()))  Tap \(status.tapID) (\(presetName(status.plan.presetID))) silent for \(String(format: "%.1f", silentFor)) s while its process is playing; rebuilt"
            watchdogEvents.append(event)
            if watchdogEvents.count > Timing.maxWatchdogEvents {
                watchdogEvents.removeFirst(watchdogEvents.count - Timing.maxWatchdogEvents)
            }
            log("Watchdog: \(event)")
            // A trim that is too large makes taps deliver nothing at all.
            graphEndedUnexpectedly()
            let remembered = quietTaps.union([key])
            tearDownAll(reason: "watchdog", graceful: false)
            // If the tap is still silent after the rebuild, the process is
            // simply playing silence; leave it be until it makes a sound.
            quietTaps = remembered
            reconcile()
            return
        }
    }

    private func quietKey(_ plan: TapPlan) -> String {
        switch plan.scope {
        case .processes: return "app:" + plan.presetID.uuidString
        case .everythingExcept: return "device:" + plan.presetID.uuidString
        }
    }

    // MARK: Published state

    private func updatePhase() {
        let newPhase: Phase
        if !isStarted {
            newPhase = .stopped
        } else if configuration.context.bypassAll {
            newPhase = .bypassed
        } else if deviceMonitor.defaultOutput == nil {
            newPhase = .noOutputDevice
        } else if graph != nil {
            newPhase = .active
        } else if pending != nil {
            newPhase = .checkingPermission
        } else if case .failed = phase, now < retryAfter {
            newPhase = phase
        } else {
            newPhase = .idle
        }
        if newPhase != phase { phase = newPhase }
        refreshDiagnostics()
    }

    /// Publishes who is playing and which preset each of them gets.
    private func publishRouting() {
        let device = deviceMonitor.defaultOutput
        let context = configuration.context
        if currentDevice != device { currentDevice = device }
        if devices != deviceMonitor.outputDevices { devices = deviceMonitor.outputDevices }

        let newDeviceResolution = Resolver.resolveDevice(deviceUID: device?.uid, in: context)
        if deviceResolution != newDeviceResolution { deviceResolution = newDeviceResolution }

        let ownPID = getpid()
        var apps: [PlayingApp] = []
        var seen = Set<String>()
        for process in processMonitor.processes where process.isRunningOutput && process.pid != ownPID {
            let identity = identities.identity(for: process)
            guard seen.insert(identity.id).inserted else { continue }
            let elsewhere = device.map { isOnOtherDevice(process, device: $0) } ?? false
            apps.append(PlayingApp(
                id: identity.id,
                name: identity.name,
                bundleURL: identity.bundleURL,
                note: identity.note,
                resolution: elsewhere
                    ? .unmatched
                    : Resolver.resolve(processBundleIDs: identity.matchIDs, deviceUID: device?.uid, in: context),
                isOnOtherDevice: elsewhere,
                matchIDs: identity.matchIDs
            ))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if playingApps != apps { playingApps = apps }
    }

    private func refreshDiagnostics() {
        var snapshot = EngineDiagnostics()
        snapshot.lastBuild = diagnostics.lastBuild
        snapshot.hasStandbyGraph = pending != nil && graph != nil
        if let shown = graph ?? pending {
            snapshot.aggregateID = shown.aggregateID
            snapshot.aggregateUID = shown.aggregateUID
            snapshot.sampleRate = shown.sampleRate
            snapshot.bufferFrameSize = shown.bufferFrameSize
            snapshot.graphLatency = shown.addedLatency
            snapshot.tapLatency = tapLatency(of: shown)
            snapshot.latencyTrimFrames = shown.plan.latencyTrimFrames
            snapshot.inputLayout = shown.inputLayout
            snapshot.outputLayout = shown.outputLayout
            switch shown.mode {
            case .probe: snapshot.mode = "Listening only (checking permission)"
            case .standby: snapshot.mode = shown.isAudible ? "Equalizing" : "Standby"
            case .audible: snapshot.mode = "Equalizing"
            }
            snapshot.outputPeak = shown.outputPeak
            snapshot.layoutMismatches = shown.layoutMismatches
            snapshot.taps = shown.tapStatuses().map { status in
                EngineDiagnostics.Tap(
                    id: status.tapID,
                    presetName: presetName(status.plan.presetID),
                    scope: describe(status.plan.scope),
                    silentSeconds: status.silentSeconds,
                    hasCarriedAudio: status.hasCarriedAudio,
                    inputPeak: status.inputPeak
                )
            }
        }
        if snapshot != diagnostics { diagnostics = snapshot }
    }

    private func presetName(_ id: UUID) -> String {
        configuration.presets[id]?.name ?? "missing preset"
    }

    private func describe(_ scope: TapScope) -> String {
        func names(_ objectIDs: [AudioObjectID]) -> String {
            let byObject = Dictionary(processMonitor.processes.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
            var counts: [String: Int] = [:]
            var order: [String] = []
            for objectID in objectIDs {
                let label: String
                if let process = byObject[objectID] {
                    label = process.bundleID.isEmpty ? "pid \(process.pid)" : process.bundleID
                } else {
                    label = "#\(objectID)"
                }
                if counts[label] == nil { order.append(label) }
                counts[label, default: 0] += 1
            }
            return order.map { label in
                let count = counts[label, default: 1]
                return count > 1 ? "\(label) ×\(count)" : label
            }.joined(separator: ", ")
        }
        switch scope {
        case .processes(let objectIDs): return names(objectIDs)
        case .everythingExcept(let objectIDs): return "everything except " + names(objectIDs)
        }
    }

    private func describe(_ plan: GraphPlan) -> String {
        plan.taps.map { "[\(presetName($0.presetID)): \(describe($0.scope))]" }.joined(separator: " ")
    }

    // MARK: Logging

    private func log(_ message: String) {
        let line = "\(logTimeFormatter.string(from: Date()))  \(message)"
        logLines.append(line)
        if logLines.count > Timing.maxLogLines {
            logLines.removeFirst(logLines.count - Timing.maxLogLines)
        }
        logger.info("\(message, privacy: .public)")
        logFile?.write(Data((line + "\n").utf8))
    }

    /// With `TAPEQ_LOG_FILE` set (development runs) the levels are written
    /// once a second, so a run can be checked without the UI. `TAPEQ_TRACE`
    /// adds a line per tick with the silence counters of every tap.
    private func writeDevelopmentLog() {
        guard logFile != nil else { return }
        if ProcessInfo.processInfo.environment["TAPEQ_TRACE"] != nil {
            for target in [graph, pending].compactMap({ $0 }) {
                let taps = target.tapStatuses().map {
                    String(format: "%u silentNow=%.3f silentTotal=%.3f", $0.tapID, $0.silentSeconds, $0.totalSilentSeconds)
                }.joined(separator: "; ")
                log(String(format: "trace up=%.3f %@ cb=%llu out=%.5f | %@",
                           now, target.isAudible ? "audible" : "\(target.mode)", target.callbackCount, target.outputPeak, taps))
            }
        }
        ticksSinceStatsLine += 1
        guard ticksSinceStatsLine >= 4 else { return }
        ticksSinceStatsLine = 0
        let taps = diagnostics.taps.map {
            String(format: "tap %u %@ in=%.5f silent=%.1fs", $0.id, $0.presetName, $0.inputPeak, $0.silentSeconds)
        }.joined(separator: "; ")
        log(String(format: "stats: %@ out=%.5f graph latency=%.1f ms tap latency=%.1f ms | %@",
                   diagnostics.mode, diagnostics.outputPeak, diagnostics.graphLatency * 1000, diagnostics.tapLatency * 1000, taps))
    }
}
