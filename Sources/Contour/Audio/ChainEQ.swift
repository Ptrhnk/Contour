import CContourAtomics
import ContourDSP
import Foundation

/// Triple-buffered handoff of a flattened coefficient set to the audio thread.
///
/// Same shape as `TripleBuffer`, but the payload is a fixed-size run of
/// `Double`s rather than a `BitwiseCopyable` value, so it can be handed to vDSP
/// as a pointer with no copy and no allocation on the realtime side.
final class CoefficientPublisher: @unchecked Sendable {

    let sections: Int
    let channels: Int
    /// Doubles per slot.
    private let slotStride: Int
    private let storage: UnsafeMutablePointer<Double>
    private let counter: UnsafeMutablePointer<ContourAtomicUInt32>
    private var nextWrite: UInt32 = 1

    init(sections: Int, channels: Int) {
        self.sections = sections
        self.channels = channels
        slotStride = sections * channels * 5
        storage = .allocate(capacity: slotStride * 3)
        storage.initialize(repeating: 0, count: slotStride * 3)
        counter = .allocate(capacity: 1)
        contour_atomic_init(counter, 0)

        let identity = EQKernel.flatten(
            Array(repeating: BiquadCoefficients.identity, count: sections),
            sections: sections,
            channels: channels)
        for slot in 0..<3 {
            identity.withUnsafeBufferPointer {
                (storage + slot * slotStride).update(from: $0.baseAddress!, count: slotStride)
            }
        }
    }

    deinit {
        storage.deinitialize(count: slotStride * 3)
        storage.deallocate()
        counter.deallocate()
    }

    /// UI thread only.
    func publish(_ coefficients: [BiquadCoefficients]) {
        let flat = EQKernel.flatten(coefficients, sections: sections, channels: channels)
        guard flat.count == slotStride else { return }
        let slot = Int(nextWrite % 3)
        flat.withUnsafeBufferPointer {
            (storage + slot * slotStride).update(from: $0.baseAddress!, count: slotStride)
        }
        contour_atomic_store(counter, nextWrite)
        nextWrite &+= 1
    }

    /// Realtime thread only.
    @inline(__always)
    var generation: UInt32 { contour_atomic_load(counter) }

    @inline(__always)
    func pointer(for generation: UInt32) -> UnsafePointer<Double> {
        UnsafePointer(storage + Int(generation % 3) * slotStride)
    }
}

/// One chain's EQ: the vDSP cascade plus the coefficient handoff.
///
/// A disabled EQ publishes identity coefficients rather than being skipped, so
/// turning it off ramps to flat over ~20 ms instead of clicking, and the
/// realtime path has no branch that can go stale.
final class ChainEQ: @unchecked Sendable {

    let kernel: EQKernel
    let publisher: CoefficientPublisher
    /// Touched only by the realtime thread.
    private var lastGeneration: UInt32 = 0

    init(maximumFrames: Int, sampleRate: Double) {
        kernel = EQKernel(sections: EQBand.count,
                          channels: 2,
                          maximumFrames: maximumFrames,
                          sampleRate: sampleRate)
        publisher = CoefficientPublisher(sections: EQBand.count, channels: 2)
    }

    /// UI thread.
    func update(settings: EQSettings, sampleRate: Double) {
        let coefficients: [BiquadCoefficients]
        if settings.isEnabled {
            coefficients = settings.bands.map {
                EQDesign.coefficients(for: $0,
                                      sampleRate: sampleRate,
                                      adaptiveQ: settings.adaptiveQ)
            }
        } else {
            coefficients = Array(repeating: .identity, count: EQBand.count)
        }
        publisher.publish(coefficients)
    }

    func reset() {
        kernel.reset()
        lastGeneration = 0
    }

    /// Realtime thread. No allocation, no locks.
    @inline(__always)
    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 frames: Int) {
        let generation = publisher.generation
        if generation != lastGeneration {
            lastGeneration = generation
            kernel.setTargets(raw: publisher.pointer(for: generation))
        }
        kernel.process(left: left, right: right, frames: frames)
    }
}
