//
//  ProcessMonitor.swift
//  TapEQ
//
//  Tracks the processes known to the audio system and which of them are
//  currently playing.
//

import AppKit
import CoreAudio
import Foundation

/// One client process of the audio system.
struct AudioProcess: Equatable, Identifiable, Sendable {
    /// The HAL object that stands for the process. This is what taps take.
    let objectID: AudioObjectID
    let pid: pid_t
    /// Bundle identifier as the audio system reports it. Empty for plain
    /// executables such as command-line tools.
    let bundleID: String
    /// Whether the process is running audio output right now.
    var isRunningOutput: Bool
    /// The devices the process is playing to. Empty while it is not playing.
    var outputDeviceIDs: [AudioObjectID]

    var id: AudioObjectID { objectID }

    /// Reads the current state of one process object. Returns nil when the
    /// process has gone away.
    static func read(_ objectID: AudioObjectID) -> AudioProcess? {
        guard let pid = try? objectID.read(kAudioProcessPropertyPID, as: pid_t.self, initial: -1), pid >= 0 else {
            return nil
        }
        let bundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)) ?? ""
        let running = (try? objectID.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self, initial: 0)) ?? 0
        let devices = (try? objectID.readArray(
            kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput, of: AudioObjectID.self
        )) ?? []
        return AudioProcess(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            isRunningOutput: running != 0,
            outputDeviceIDs: devices
        )
    }

    /// Every process the audio system knows about right now.
    static func all() -> [AudioProcess] {
        let objectIDs = (try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self
        )) ?? []
        return objectIDs.compactMap(read)
    }
}

/// Publishes the process list and keeps it current.
@MainActor
final class ProcessMonitor {
    private(set) var processes: [AudioProcess] = []

    /// Called on the main actor after `processes` changed.
    var onChange: (() -> Void)?

    private var listListener: AudioPropertyListener?
    private var outputListeners: [AudioObjectID: [AudioPropertyListener]] = [:]

    func start() {
        guard listListener == nil else { return }
        listListener = AudioPropertyListener(
            object: .system,
            selector: kAudioHardwarePropertyProcessObjectList
        ) { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        listListener = nil
        outputListeners.removeAll()
    }

    /// Re-reads the whole list and re-arms the per-process listeners.
    func refresh() {
        let current = AudioProcess.all()
        let currentIDs = Set(current.map(\.objectID))

        for objectID in outputListeners.keys where !currentIDs.contains(objectID) {
            outputListeners[objectID] = nil
        }
        for process in current where outputListeners[process.objectID] == nil {
            let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
                (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
                (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
            ]
            outputListeners[process.objectID] = watched.compactMap { selector, scope in
                AudioPropertyListener(object: process.objectID, selector: selector, scope: scope) { [weak self] in
                    self?.refresh()
                }
            }
        }

        guard current != processes else { return }
        processes = current
        onChange?()
    }
}
