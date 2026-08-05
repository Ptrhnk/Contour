import CoreAudio
import Foundation

/// Thin, throwing wrapper over the AudioObject property API.
/// Nothing here may be called from the realtime thread.
enum CA {

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus?
        let what: String

        var description: String {
            guard let status else { return what }
            return "\(what) (\(CA.describe(status)))"
        }
    }

    static func describe(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                     UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)' / \(status)"
        }
        return "\(status)"
    }

    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
        guard status == noErr else { throw Failure(status: status, what: what()) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func dataSize(_ object: AudioObjectID,
                         _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
                  "dataSize \(address.mSelector)")
        return size
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID,
                         _ address: AudioObjectPropertyAddress,
                         default fallback: T) throws -> T {
        var address = address
        var out = fallback
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &out),
                  "get \(address.mSelector)")
        return out
    }

    static func setValue<T: BitwiseCopyable>(_ object: AudioObjectID,
                            _ address: AudioObjectPropertyAddress,
                            _ newValue: T) throws {
        var address = address
        var v = newValue
        try check(AudioObjectSetPropertyData(object, &address, 0, nil,
                                             UInt32(MemoryLayout<T>.size), &v),
                  "set \(address.mSelector)")
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID,
                         _ address: AudioObjectPropertyAddress,
                         of type: T.Type) throws -> [T] {
        var address = address
        let size = try dataSize(object, address)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var out = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        var s = size
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &s, &out),
                  "getArray \(address.mSelector)")
        return out
    }

    static func string(_ object: AudioObjectID,
                       _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let cf else { return nil }
        return cf as String
    }

    /// Channel count per buffer in a device's stream configuration, in stream order.
    /// The aggregate concatenates its sub-devices in sub-device-list order, so this
    /// is what maps a logical channel onto (buffer index, offset within buffer).
    static func streamChannels(_ object: AudioObjectID,
                               scope: AudioObjectPropertyScope) throws -> [Int] {
        let address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        let size = try dataSize(object, address)
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var a = address
        var s = size
        try check(AudioObjectGetPropertyData(object, &a, 0, nil, &s, raw),
                  "streamConfiguration")
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func channelCount(_ object: AudioObjectID,
                             scope: AudioObjectPropertyScope) -> Int {
        ((try? streamChannels(object, scope: scope)) ?? []).reduce(0, +)
    }
}
