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
            let renderer = try AggregateRenderer(aggregate: aggregate,
                                                 chainAPairIndex: chainAPairIndex,
                                                 chainBPairIndex: chainBPairIndex,
                                                 source: "tap \(tap.id)")
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
