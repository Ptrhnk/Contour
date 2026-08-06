import AVFoundation
import CoreAudio

/// Backend B. System output is set to BlackHole; Contour reads it back out of the
/// aggregate and writes the processed result to the interface's channel pairs.
///
/// Works on every macOS version and needs no permission prompt, at the cost of
/// requiring BlackHole to be installed and the system output to be pointed at it.
final class BlackHoleSource: AudioSource {

    private let interface: AudioDevice
    private let capture: AudioDevice
    private let chainAPairIndex: Int
    private let chainBPairIndex: Int?

    private var renderer: AggregateRenderer?
    private var fallbackFormat: AVAudioFormat

    init(interface: AudioDevice,
         capture: AudioDevice,
         chainAPairIndex: Int,
         chainBPairIndex: Int?) {
        self.interface = interface
        self.capture = capture
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
        let aggregate = try AggregateDevice.create(interface: interface, capture: capture)
        let renderer: AggregateRenderer
        do {
            renderer = try AggregateRenderer(aggregate: aggregate,
                                             chainAPairIndex: chainAPairIndex,
                                             chainBPairIndex: chainBPairIndex,
                                             source: "blackhole \(capture.name)")
        } catch {
            // The renderer owns the aggregate only once it exists.
            aggregate.destroy()
            throw error
        }
        try renderer.start(render)
        self.renderer = renderer
    }

    func stop() {
        renderer?.stop()
        renderer = nil
    }

    deinit { stop() }

    func consumeMeters() -> AggregateRenderer.Meters {
        renderer?.consumeMeters() ?? AggregateRenderer.Meters()
    }
}
