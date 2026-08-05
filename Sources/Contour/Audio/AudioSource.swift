import AVFoundation

/// Planar float buffers handed to the render block on the realtime thread.
/// Every pointer is pre-allocated at setup; the render block must not allocate,
/// lock, log, or touch ARC.
struct RenderBuffers {
    let inputL: UnsafeMutablePointer<Float>
    let inputR: UnsafeMutablePointer<Float>
    let chainAL: UnsafeMutablePointer<Float>
    let chainAR: UnsafeMutablePointer<Float>
    let chainBL: UnsafeMutablePointer<Float>
    let chainBR: UnsafeMutablePointer<Float>
    let frameCount: Int
}

/// The render block fills chainA/chainB from input. The source is responsible for
/// getting input in and chain output back out to the right channel pairs.
typealias RenderBlock = @Sendable (RenderBuffers) -> Void

/// Where the audio comes from. Backend B (BlackHole) and Backend A (process tap)
/// both implement this; everything downstream is identical either way.
protocol AudioSource: AnyObject {
    var format: AVAudioFormat { get }
    /// Total output latency of the underlying device path, in frames.
    var outputLatencyFrames: Int { get }
    func start(_ render: @escaping RenderBlock) throws
    func stop()
}
