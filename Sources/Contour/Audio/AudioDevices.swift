import CoreAudio
import Foundation

/// What the device physically is, so the UI can say "AirPods Pro" with the
/// right icon rather than calling everything "Speakers".
enum AudioDeviceKind: Sendable {
    case headphones
    case speakers
    case unknown
}

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let transportType: UInt32
    /// From `kAudioStreamPropertyTerminalType` on the first output stream.
    let outputTerminalType: UInt32

    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }
    var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Core Audio reports this properly for the cases that matter — AirPods
    /// answer `'hdph'` — so this is real detection rather than name matching.
    /// USB devices report the USB audio class terminal numbers instead, where
    /// 0x0301 is a speaker and 0x0302 headphones.
    var kind: AudioDeviceKind {
        switch outputTerminalType {
        case kAudioStreamTerminalTypeHeadphones, 0x0302: return .headphones
        case kAudioStreamTerminalTypeSpeaker,
             kAudioStreamTerminalTypeReceiverSpeaker,
             0x0301: return .speakers
        default: break
        }
        // Fallback for devices that report nothing useful.
        let lowercased = name.lowercased()
        for hint in ["airpod", "headphone", "headset", "beats", "buds", "hd 6", "hd6"]
        where lowercased.contains(hint) {
            return .headphones
        }
        return .unknown
    }

    /// Drops the possessive prefix macOS puts on Bluetooth devices, so
    /// "Langoš's AirPods Pro" reads as "AirPods Pro".
    var shortName: String {
        for separator in ["\u{2019}s ", "'s "] {
            if let range = name.range(of: separator) {
                return String(name[range.upperBound...])
            }
        }
        return name
    }

    var symbolName: String {
        let lowercased = name.lowercased()
        if lowercased.contains("airpods max") { return "airpodsmax" }
        if lowercased.contains("airpods pro") { return "airpods.pro" }
        if lowercased.contains("airpods") { return "airpods" }
        if lowercased.contains("beats") { return "beats.headphones" }
        switch kind {
        case .headphones: return "headphones"
        case .speakers: return isBluetooth ? "hifispeaker.fill" : "hifispeaker"
        case .unknown: return "speaker.wave.2"
        }
    }
}

enum AudioDevices {

    static let blackHoleUID = "BlackHole2ch_UID"

    static func all() -> [AudioDevice] {
        let address = CA.address(kAudioHardwarePropertyDevices)
        let ids = (try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                                 address, of: AudioObjectID.self)) ?? []
        return ids.compactMap(describe)
    }

    static func describe(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = CA.string(id, CA.address(kAudioDevicePropertyDeviceUID)) else {
            return nil
        }
        let name = CA.string(id, CA.address(kAudioObjectPropertyName)) ?? uid
        let sampleRate = (try? CA.value(id, CA.address(kAudioDevicePropertyNominalSampleRate),
                                        default: Double(0))) ?? 0
        let transport = (try? CA.value(id, CA.address(kAudioDevicePropertyTransportType),
                                       default: UInt32(0))) ?? 0
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            sampleRate: sampleRate,
            transportType: transport,
            outputTerminalType: outputTerminalType(id))
    }

    private static func outputTerminalType(_ id: AudioObjectID) -> UInt32 {
        let streams = (try? CA.array(id,
                                     CA.address(kAudioDevicePropertyStreams,
                                                scope: kAudioObjectPropertyScopeOutput),
                                     of: AudioObjectID.self)) ?? []
        for stream in streams {
            if let type = try? CA.value(stream,
                                        CA.address(kAudioStreamPropertyTerminalType),
                                        default: UInt32(0)), type != 0 {
                return type
            }
        }
        return 0
    }

    static func device(uid: String) -> AudioDevice? {
        all().first { $0.uid == uid }
    }

    static func blackHole() -> AudioDevice? {
        device(uid: blackHoleUID) ?? all().first { $0.name.hasPrefix("BlackHole") }
    }

    /// Physical output devices Contour can render into. Excludes BlackHole itself,
    /// other virtual drivers, and aggregates (nesting aggregates is not supported).
    static func candidateInterfaces() -> [AudioDevice] {
        all().filter {
            $0.outputChannels >= 2 && !$0.isVirtual && !$0.isAggregate
                && $0.uid != blackHoleUID && !$0.name.hasPrefix("BlackHole")
        }
    }

    /// Most output channels wins, so a 4-channel interface beats built-in speakers.
    static func preferredInterface() -> AudioDevice? {
        candidateInterfaces().max { a, b in
            (a.outputChannels, a.name) < (b.outputChannels, b.name)
        }
    }

    // MARK: - System output device

    static func defaultOutputDevice() -> AudioDevice? {
        guard let id = try? CA.value(AudioObjectID(kAudioObjectSystemObject),
                                     CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                                     default: AudioObjectID(0)), id != 0 else { return nil }
        return describe(id)
    }

    static func setDefaultOutputDevice(_ device: AudioDevice) throws {
        try CA.setValue(AudioObjectID(kAudioObjectSystemObject),
                        CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                        device.id)
    }

    // MARK: - Volume

    /// BlackHole exposes a software volume control, so the system slider attenuates
    /// in the digital domain before Contour ever sees the audio. Returns nil for
    /// devices with no software volume (most interfaces).
    static func outputVolumeScalar(_ device: AudioDevice) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            let address = CA.address(kAudioDevicePropertyVolumeScalar,
                                     scope: kAudioObjectPropertyScopeOutput,
                                     element: AudioObjectPropertyElement(element))
            if CA.has(device.id, address),
               let v = try? CA.value(device.id, address, default: Float(0)) {
                return v
            }
        }
        return nil
    }

    static func setOutputVolumeScalar(_ device: AudioDevice, _ value: Float) throws {
        var lastError: Error?
        var didSet = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let address = CA.address(kAudioDevicePropertyVolumeScalar,
                                     scope: kAudioObjectPropertyScopeOutput,
                                     element: AudioObjectPropertyElement(element))
            guard CA.has(device.id, address) else { continue }
            do {
                try CA.setValue(device.id, address, value)
                didSet = true
            } catch {
                lastError = error
            }
        }
        if !didSet, let lastError { throw lastError }
    }
}
