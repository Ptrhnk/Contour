import CoreAudio
import Foundation

/// Where one logical channel of an aggregate device actually lives:
/// which AudioBuffer, at what offset, with what interleave stride.
struct ChannelSlot {
    let buffer: Int
    let offset: Int
    let stride: Int
}

/// A stereo pair. Both channels must sit in the same AudioBuffer, which holds
/// for every sub-device pair since a sub-device contributes one buffer.
struct ChannelPairSlot {
    let buffer: Int
    let leftOffset: Int
    let stride: Int
}

/// The private aggregate that joins the capture device and the output interface
/// into one clock domain, so a single IOProc reads and writes both.
final class AggregateDevice {

    static let uid = "com.nahak.contour.aggregate"

    let id: AudioObjectID
    let interface: AudioDevice
    let capture: AudioDevice?
    let inputStreams: [Int]
    let outputStreams: [Int]

    private var destroyed = false

    private init(id: AudioObjectID,
                 interface: AudioDevice,
                 capture: AudioDevice?,
                 inputStreams: [Int],
                 outputStreams: [Int]) {
        self.id = id
        self.interface = interface
        self.capture = capture
        self.inputStreams = inputStreams
        self.outputStreams = outputStreams
    }

    /// Tap flavour: the interface is the only sub-device, and system audio
    /// arrives through the tap rather than a virtual capture device. No
    /// BlackHole involved.
    @available(macOS 14.2, *)
    static func create(interface: AudioDevice, tap: ProcessTap) throws -> AggregateDevice {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Contour",
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: interface.uid,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: interface.uid,
                 kAudioSubDeviceDriftCompensationKey as String: 0],
            ],
            // Explicitly off. With auto-start on, the tap runs itself and our
            // IOProc is never called at all — measured as exactly 0 callbacks
            // while auto-start off gives the full 93.75/s at 512 frames. It only
            // appeared to work when something else already had the interface
            // running, which is what made it look like an intermittent fault.
            // Auto-start is for holding a tap open with no client; Contour is
            // the client.
            kAudioAggregateDeviceTapAutoStartKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tap.uuid,
                 kAudioSubTapDriftCompensationKey as String: 1],
            ],
        ]
        return try create(description: description, interface: interface, capture: nil)
    }

    /// BlackHole flavour. The interface goes first in the sub-device list so its
    /// outputs occupy logical channels 0..n-1, and it is the clock master. Drift
    /// compensation runs on the capture device, never on the master.
    static func create(interface: AudioDevice, capture: AudioDevice) throws -> AggregateDevice {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Contour",
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: interface.uid,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: interface.uid,
                 kAudioSubDeviceDriftCompensationKey as String: 0],
                [kAudioSubDeviceUIDKey as String: capture.uid,
                 kAudioSubDeviceDriftCompensationKey as String: 1],
            ],
        ]

        return try create(description: description, interface: interface, capture: capture)
    }

    private static func create(description: [String: Any],
                               interface: AudioDevice,
                               capture: AudioDevice?) throws -> AggregateDevice {
        var id: AudioObjectID = 0
        try CA.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id),
                     "create aggregate device")
        guard id != 0 else {
            throw CA.Failure(status: nil, what: "aggregate device created with id 0")
        }

        // The interface is the clock master, so the aggregate runs at its rate.
        if interface.sampleRate > 0 {
            try? CA.setValue(id, CA.address(kAudioDevicePropertyNominalSampleRate),
                             interface.sampleRate)
        }

        let inputStreams = try CA.streamChannels(id, scope: kAudioObjectPropertyScopeInput)
        let outputStreams = try CA.streamChannels(id, scope: kAudioObjectPropertyScopeOutput)

        let device = AggregateDevice(id: id,
                                     interface: interface,
                                     capture: capture,
                                     inputStreams: inputStreams,
                                     outputStreams: outputStreams)

        do {
            try device.verifyFloat32()
        } catch {
            device.destroy()
            throw error
        }
        return device
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(id)
    }

    deinit { destroy() }

    var sampleRate: Double {
        (try? CA.value(id, CA.address(kAudioDevicePropertyNominalSampleRate),
                       default: Double(0))) ?? 0
    }

    var bufferFrameSize: Int {
        Int((try? CA.value(id, CA.address(kAudioDevicePropertyBufferFrameSize),
                           default: UInt32(0))) ?? 0)
    }

    /// Output latency of the aggregate plus its safety offset, in frames.
    var outputLatencyFrames: Int {
        let latency = (try? CA.value(id, CA.address(kAudioDevicePropertyLatency,
                                                    scope: kAudioObjectPropertyScopeOutput),
                                     default: UInt32(0))) ?? 0
        let safety = (try? CA.value(id, CA.address(kAudioDevicePropertySafetyOffset,
                                                   scope: kAudioObjectPropertyScopeOutput),
                                    default: UInt32(0))) ?? 0
        return Int(latency + safety)
    }

    // MARK: - Channel mapping

    /// Sub-devices are concatenated in sub-device-list order, one buffer each,
    /// interleaved within the buffer. Verified empirically before this was written.
    static func slot(logicalChannel channel: Int, in streams: [Int]) -> ChannelSlot? {
        var base = 0
        for (index, channels) in streams.enumerated() {
            if channel < base + channels {
                return ChannelSlot(buffer: index, offset: channel - base, stride: channels)
            }
            base += channels
        }
        return nil
    }

    static func pairSlot(startingAt channel: Int, in streams: [Int]) -> ChannelPairSlot? {
        guard let left = slot(logicalChannel: channel, in: streams),
              let right = slot(logicalChannel: channel + 1, in: streams),
              left.buffer == right.buffer,
              right.offset == left.offset + 1
        else { return nil }
        return ChannelPairSlot(buffer: left.buffer, leftOffset: left.offset, stride: left.stride)
    }

    /// Whatever supplies system audio — the capture device or the tap — comes
    /// after every input the interface itself has, in both flavours.
    var captureInputPair: ChannelPairSlot? {
        Self.pairSlot(startingAt: interface.inputChannels, in: inputStreams)
    }

    /// Interface output pair for a zero-based pair index (0 = ch 1/2, 1 = ch 3/4).
    func interfaceOutputPair(_ index: Int) -> ChannelPairSlot? {
        Self.pairSlot(startingAt: index * 2, in: outputStreams)
    }

    var interfaceOutputPairCount: Int { interface.outputChannels / 2 }

    // MARK: - Format

    private func verifyFloat32() throws {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            let streams = (try? CA.array(id, CA.address(kAudioDevicePropertyStreams, scope: scope),
                                         of: AudioObjectID.self)) ?? []
            for stream in streams {
                guard let format = try? CA.value(
                    stream,
                    CA.address(kAudioStreamPropertyVirtualFormat),
                    default: AudioStreamBasicDescription())
                else { continue }
                let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                guard isFloat, format.mBitsPerChannel == 32 else {
                    throw CA.Failure(
                        status: nil,
                        what: "aggregate stream is not 32-bit float "
                            + "(bits: \(format.mBitsPerChannel), flags: \(format.mFormatFlags))")
                }
            }
        }
    }
}
