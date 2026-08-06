import CContourAtomics
import CoreAudio
import Foundation

/// The plugins around the EQ, in order.
///
/// Split into before/after rather than a heterogeneous list because the EQ is a
/// single fixed object owned by the chain, and "drag the EQ above or below a
/// plugin" (§4) is exactly the position of one divider. It also keeps the
/// realtime walk free of enum payloads holding class references.
final class ProcessingGraph: @unchecked Sendable {
    let before: [PluginHost]
    let after: [PluginHost]

    init(before: [PluginHost], after: [PluginHost]) {
        self.before = before
        self.after = after
    }

    static let empty = ProcessingGraph(before: [], after: [])

    var plugins: [PluginHost] { before + after }
    var latencyFrames: Int { plugins.reduce(0) { $0 + $1.latencyFrames } }
}

/// Publishes a new graph to the audio thread without it ever allocating,
/// locking, or waiting.
///
/// A changed plugin set means instantiating and allocating render resources,
/// which happens on a background thread; only the index swap is seen by the
/// realtime side (§6a). Three slots keep the outgoing graph alive well past the
/// callback that might still be reading it — a plugin freed underneath the audio
/// thread would be a crash, not a glitch.
final class ProcessingGraphPublisher: @unchecked Sendable {

    private static let slotCount = 3

    private let slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private let published: UnsafeMutablePointer<ContourAtomicUInt32>
    private var nextWrite: UInt32 = 1

    init() {
        slots = .allocate(capacity: Self.slotCount)
        slots.initialize(repeating: nil, count: Self.slotCount)
        published = .allocate(capacity: 1)
        contour_atomic_init(published, 0)
        slots[0] = Unmanaged.passRetained(ProcessingGraph.empty).toOpaque()
    }

    deinit {
        for slot in 0..<Self.slotCount {
            if let pointer = slots[slot] {
                Unmanaged<ProcessingGraph>.fromOpaque(pointer).release()
            }
        }
        slots.deallocate()
        published.deallocate()
    }

    /// Main thread only.
    func publish(_ graph: ProcessingGraph) {
        let slot = Int(nextWrite) % Self.slotCount
        if let previous = slots[slot] {
            Unmanaged<ProcessingGraph>.fromOpaque(previous).release()
        }
        slots[slot] = Unmanaged.passRetained(graph).toOpaque()
        contour_atomic_store(published, nextWrite)
        nextWrite &+= 1
    }

    /// Realtime thread only.
    @inline(__always)
    func current() -> ProcessingGraph? {
        let index = Int(contour_atomic_load(published)) % Self.slotCount
        guard let pointer = slots[index] else { return nil }
        return Unmanaged<ProcessingGraph>.fromOpaque(pointer).takeUnretainedValue()
    }
}
