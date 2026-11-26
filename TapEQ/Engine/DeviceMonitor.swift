//
//  DeviceMonitor.swift
//  TapEQ
//
//  Tracks the output devices, which of them is the system default, and the
//  format of the default one.
//

import CoreAudio
import Foundation

/// An output device as the HAL reports it right now.
struct OutputDevice: Equatable, Identifiable, Sendable {
    let objectID: AudioObjectID
    /// Persistent identifier. Rules refer to devices by this.
    let uid: String
    let name: String
    /// One of the `kAudioDeviceTransportType…` constants.
    let transportType: UInt32

    var id: String { uid }

    var isAggregate: Bool {
        transportType == kAudioDeviceTransportTypeAggregate
    }

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// An SF Symbol that suits the kind of device.
    var symbolName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        default: return "hifispeaker"
        }
    }

    static func read(_ objectID: AudioObjectID) -> OutputDevice? {
        guard let uid = try? objectID.readString(kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        let name = (try? objectID.readString(kAudioObjectPropertyName)) ?? uid
        let transport = (try? objectID.read(kAudioDevicePropertyTransportType, as: UInt32.self, initial: 0)) ?? 0
        return OutputDevice(objectID: objectID, uid: uid, name: name, transportType: transport)
    }
}

/// The properties of a device that the audio graph is built around. When any
/// of them changes, a graph built on the device is stale.
struct DeviceFormat: Equatable, Sendable {
    let sampleRate: Double
    /// Channels per output buffer.
    let outputLayout: [Int]
    /// The output latency the device reports, in frames. Large for
    /// Bluetooth (7,680 frames, 160 ms, on AirPods Max).
    let outputLatencyFrames: Int

    var outputLatency: Double {
        sampleRate > 0 ? Double(outputLatencyFrames) / sampleRate : 0
    }

    static func read(_ objectID: AudioObjectID) -> DeviceFormat {
        DeviceFormat(
            sampleRate: (try? objectID.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self, initial: 0)) ?? 0,
            outputLayout: (try? objectID.channelLayout(scope: kAudioObjectPropertyScopeOutput)) ?? [],
            outputLatencyFrames: Int((try? objectID.read(
                kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self, initial: 0
            )) ?? 0)
        )
    }
}

@MainActor
final class DeviceMonitor {
    /// Every usable output device, in the order the system lists them.
    private(set) var outputDevices: [OutputDevice] = []
    /// The system default output device, if it is one this app can use.
    private(set) var defaultOutput: OutputDevice?
    /// The format of the default output device.
    private(set) var defaultFormat: DeviceFormat?

    /// A different device became the default output (or there is none now).
    var onDefaultOutputChanged: (() -> Void)?
    /// A device was connected, disconnected or renamed.
    var onDevicesChanged: (() -> Void)?
    /// The default output device kept its identity but changed sample rate
    /// or channel layout, as Bluetooth headphones do when a call starts.
    var onDefaultFormatChanged: (() -> Void)?

    private var systemListeners: [AudioPropertyListener] = []
    private var deviceListeners: [AudioPropertyListener] = []

    func start() {
        guard systemListeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            if let listener = AudioPropertyListener(object: .system, selector: selector, handler: { [weak self] in
                self?.refresh()
            }) {
                systemListeners.append(listener)
            }
        }
        refresh()
    }

    func stop() {
        systemListeners.removeAll()
        deviceListeners.removeAll()
    }

    /// Re-reads everything and reports what changed. Listeners can fire for
    /// reasons that leave the picture unchanged (this app's own private
    /// aggregate coming and going, for one), so every callback is driven by a
    /// comparison, never by the notification alone.
    func refresh() {
        let devices = Self.readOutputDevices()
        var defaultID = (try? AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self, initial: .unknown
        )) ?? .unknown
        #if DEBUG
        // Development hook: treat another device as the output, so the
        // engine can be exercised without changing the system setting.
        if let forcedUID = ProcessInfo.processInfo.environment["TAPEQ_OUTPUT_DEVICE_UID"], !forcedUID.isEmpty {
            defaultID = AudioObjectID.device(forUID: forcedUID) ?? .unknown
        }
        #endif
        let newDefault = devices.first { $0.objectID == defaultID }
        let newFormat = newDefault.map { DeviceFormat.read($0.objectID) }

        let devicesChanged = devices != outputDevices
        let defaultChanged = newDefault?.uid != defaultOutput?.uid || newDefault?.objectID != defaultOutput?.objectID
        let formatChanged = !defaultChanged && newFormat != defaultFormat

        outputDevices = devices
        defaultOutput = newDefault
        defaultFormat = newFormat

        if defaultChanged {
            listenToDefaultDevice()
        }
        if devicesChanged { onDevicesChanged?() }
        if defaultChanged { onDefaultOutputChanged?() }
        if formatChanged { onDefaultFormatChanged?() }
    }

    private func listenToDefaultDevice() {
        deviceListeners.removeAll()
        guard let device = defaultOutput else { return }
        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
        ]
        for (selector, scope) in watched {
            if let listener = AudioPropertyListener(object: device.objectID, selector: selector, scope: scope, handler: { [weak self] in
                self?.refresh()
            }) {
                deviceListeners.append(listener)
            }
        }
    }

    private static func readOutputDevices() -> [OutputDevice] {
        let objectIDs = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)) ?? []
        return objectIDs.compactMap { objectID in
            guard let device = OutputDevice.read(objectID),
                  // This app's own private aggregate is visible to this
                  // process (and to no other); it is not a device to offer.
                  !device.uid.hasPrefix(TapGraph.aggregateUIDPrefix),
                  let layout = try? objectID.channelLayout(scope: kAudioObjectPropertyScopeOutput),
                  layout.contains(where: { $0 > 0 })
            else { return nil }
            let hidden = (try? objectID.read(kAudioDevicePropertyIsHidden, as: UInt32.self, initial: 0)) ?? 0
            return hidden == 0 ? device : nil
        }
    }
}
