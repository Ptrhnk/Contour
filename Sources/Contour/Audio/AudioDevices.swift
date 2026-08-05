import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let transportType: UInt32

    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }
    var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
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
            transportType: transport)
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
