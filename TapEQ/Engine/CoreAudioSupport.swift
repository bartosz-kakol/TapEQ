//
//  CoreAudioSupport.swift
//  TapEQ
//
//  Thin Swift wrappers over the Core Audio HAL property API.
//

import CoreAudio
import Foundation

/// A failed HAL call.
struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String {
        "\(operation) failed: \(Self.describe(status))"
    }

    /// Renders an OSStatus as its four-character code when it has one.
    static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let code = String(bytes: bytes, encoding: .ascii) {
            return "'\(code)' (\(status))"
        }
        return "\(status)"
    }
}

/// Throws `CoreAudioError` unless `status` is `noErr`.
@discardableResult
func checkStatus(_ status: OSStatus, _ operation: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
    return status
}

extension AudioObjectPropertyAddress {
    init(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func hasProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        return AudioObjectHasProperty(self, &address)
    }

    /// Reads a fixed-size plain value such as a `UInt32` or `Float64`.
    func read<Value>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: Value.Type = Value.self,
        initial: Value
    ) throws -> Value {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, bytes.baseAddress!)
        }
        try checkStatus(status, "Reading \(selector.fourCC) of object \(self)")
        return value
    }

    /// Reads a variable-length array of plain values.
    func readArray<Element>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: Element.Type = Element.self
    ) throws -> [Element] {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
            "Sizing \(selector.fourCC) of object \(self)"
        )
        let count = Int(size) / MemoryLayout<Element>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<Element>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try checkStatus(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer),
            "Reading \(selector.fourCC) of object \(self)"
        )
        // The list can shrink between the two calls.
        let read = Swift.min(count, Int(size) / MemoryLayout<Element>.stride)
        return Array(UnsafeBufferPointer(start: buffer, count: read))
    }

    /// Reads a CFString property.
    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try checkStatus(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value),
            "Reading \(selector.fourCC) of object \(self)"
        )
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// The number of channels in each buffer the device presents to an
    /// IOProc on the given side, in buffer order.
    func channelLayout(scope: AudioObjectPropertyScope) throws -> [Int] {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
            "Sizing stream configuration of device \(self)"
        )
        guard size >= UInt32(MemoryLayout<UInt32>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        try checkStatus(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw),
            "Reading stream configuration of device \(self)"
        )
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// The device with the given UID, or nil when it is not connected.
    static func device(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var deviceID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = uid as CFString
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                .system, &address,
                UInt32(MemoryLayout<CFString>.size), qualifierPointer,
                &size, &deviceID
            )
        }
        guard status == noErr, deviceID.isValid else { return nil }
        return deviceID
    }

    /// The HAL process object for a pid, or nil when that process has never
    /// talked to the audio system.
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var objectID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var qualifier = pid
        let status = AudioObjectGetPropertyData(
            .system, &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &size, &objectID
        )
        guard status == noErr, objectID.isValid else { return nil }
        return objectID
    }
}

extension AudioObjectPropertySelector {
    /// The selector as its four-character code, for log messages.
    var fourCC: String {
        let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let code = String(bytes: bytes, encoding: .ascii)
        else { return "\(self)" }
        return "'\(code)'"
    }
}

/// Calls `handler` on the main queue whenever a HAL property changes, until
/// the listener is invalidated or deallocated.
final class AudioPropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    /// Returns nil when the HAL refuses the listener, which happens when the
    /// object has already gone away.
    init?(
        object objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @MainActor () -> Void
    ) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Delivered on the main queue, as requested below.
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block) == noErr else {
            return nil
        }
        self.block = block
    }

    func invalidate() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        self.block = nil
    }

    deinit {
        invalidate()
    }
}
