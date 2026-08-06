import AVFoundation
import CoreAudio
import Foundation

/// Backend A. A muted global process tap captures everything the system plays,
/// the original path is silenced, and Contour renders the only audible copy to
/// the interface's channel pairs.
///
/// No BlackHole, and no need to point the system output anywhere in particular —
/// a global tap follows system audio wherever it goes. The costs are a macOS
/// 14.2+ requirement and an audio-capture permission grant.
@available(macOS 14.2, *)
final class TapSource: AudioSource {

    private let interface: AudioDevice
    private let chainAPairIndex: Int
    private let chainBPairIndex: Int?

    private var tap: ProcessTap?
    private var renderer: AggregateRenderer?
    private var fallbackFormat: AVAudioFormat

    init(interface: AudioDevice,
         chainAPairIndex: Int,
         chainBPairIndex: Int?) {
        self.interface = interface
        self.chainAPairIndex = chainAPairIndex
        self.chainBPairIndex = chainBPairIndex
        let rate = interface.sampleRate > 0 ? interface.sampleRate : 44_100
        fallbackFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    }

    /// A stereo tap is a **mixdown of the system output device's whole bus**, and
    /// the mixdown averages the pairs that fold into each side. Against a
    /// 4-channel device it computes `L = 0.5·(ch1 + ch3)`; ordinary stereo
    /// content lives only on 1/2, so half the sum is silence and the capture
    /// arrives exactly 6.02 dB down.
    ///
    /// Measured with a 250 Hz tone at −6.02 dBFS, median block peak:
    ///
    /// ```
    /// system output 2 ch (BlackHole)   −6.02 dBFS   unity
    /// system output 4 ch (SSL 2+)     −12.04 dBFS   exactly 0.5
    /// ```
    ///
    /// Without this the level jumps 6 dB when the Capture switch is flipped,
    /// which makes the Tap/BlackHole A/B worthless — the one comparison the
    /// backend switch exists to enable.
    ///
    /// The divisor is the number of pairs, verified at 1 and 2. It is
    /// **clamped to 2** rather than extrapolated: an 8-channel device might want
    /// 4, but guessing wrong upward means a sudden +12 dB into headphones, and
    /// undercompensating is merely quiet.
    static func captureGain(systemOutputChannels channels: Int) -> Float {
        let mixdown = Float(min(max(channels / 2, 1), 2))
        // Only where there is something to undo. A 2-channel system output loses
        // nothing, and pulling that down would be attenuating a capture that was
        // already unity.
        guard mixdown > 1 else { return 1 }
        return mixdown * pow(10, -headroomDB / 20)
    }

    /// Held back from the exact inverse. Restoring the full 6 dB puts material
    /// mastered near 0 dBFS straight onto the converter's ceiling, with the EQ
    /// still to come. Chosen by ear, not measured — it is a preference, and the
    /// cost is that the Tap/BlackHole A/B is this much off rather than matched.
    static let headroomDB: Float = 1

    var format: AVAudioFormat { renderer?.format ?? fallbackFormat }
    var outputLatencyFrames: Int { renderer?.outputLatencyFrames ?? 0 }
    var currentSampleRate: Double { renderer?.currentSampleRate ?? 0 }
    var layoutDescription: String { renderer?.layoutDescription ?? "not started" }

    func start(_ render: @escaping RenderBlock) throws {
        guard renderer == nil else { return }

        // Excluding our own process is not optional: without it Contour's own
        // output is captured and fed back into its input.
        let tap = try ProcessTap(excluding: [getpid()])
        self.tap = tap

        let aggregate: AggregateDevice
        do {
            aggregate = try AggregateDevice.create(interface: interface, tap: tap)
        } catch {
            teardown()
            throw error
        }
        do {
            // Read at start: the tap mixes down whatever the system output
            // device presents, so the compensation follows that device, not the
            // one Contour renders to.
            let systemOutput = AudioDevices.defaultOutputDevice()
            let renderer = try AggregateRenderer(
                aggregate: aggregate,
                chainAPairIndex: chainAPairIndex,
                chainBPairIndex: chainBPairIndex,
                captureGain: Self.captureGain(
                    systemOutputChannels: systemOutput?.outputChannels ?? 2),
                source: "tap \(tap.id) systemOutput "
                    + "\(systemOutput?.name ?? "unknown") \(systemOutput?.outputChannels ?? 0)ch")
            try renderer.start(render)
            self.renderer = renderer
        } catch {
            // The renderer owns the aggregate only once its init succeeded; if it
            // threw during start it has already torn the aggregate down itself.
            if renderer == nil { aggregate.destroy() }
            teardown()
            throw error
        }
    }

    func stop() {
        renderer?.stop()
        renderer = nil
        teardown()
    }

    deinit { stop() }

    /// The aggregate must go first. Destroying the tap out from under a running
    /// aggregate is the one ordering that could plausibly leave the mute stuck.
    private func teardown() {
        tap?.destroy()
        tap = nil
    }

    func consumeMeters() -> AggregateRenderer.Meters {
        renderer?.consumeMeters() ?? AggregateRenderer.Meters()
    }
}
