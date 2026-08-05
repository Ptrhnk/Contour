import CContourAtomics

/// Single-writer (UI thread) / single-reader (realtime thread) parameter handoff.
///
/// Three slots means the writer never touches the slot the reader is currently
/// reading: it publishes slot *n*, then writes slot *n+1*, so the reader always
/// has a full cycle of slack. No locks, no allocation, and the reader's cost is
/// one acquire load plus a struct copy.
final class TripleBuffer<Value>: @unchecked Sendable where Value: BitwiseCopyable {

    private let slots: UnsafeMutablePointer<Value>
    private let published: UnsafeMutablePointer<ContourAtomicUInt32>
    /// Writer-only cursor, never read by the realtime thread.
    private var nextWrite: UInt32 = 1

    init(_ initial: Value) {
        slots = .allocate(capacity: 3)
        slots.initialize(repeating: initial, count: 3)
        published = .allocate(capacity: 1)
        contour_atomic_init(published, 0)
    }

    deinit {
        slots.deinitialize(count: 3)
        slots.deallocate()
        published.deallocate()
    }

    /// UI thread only.
    func publish(_ value: Value) {
        slots[Int(nextWrite)] = value
        contour_atomic_store(published, nextWrite)
        nextWrite = (nextWrite + 1) % 3
    }

    /// Realtime thread only.
    @inline(__always)
    func current() -> Value {
        slots[Int(contour_atomic_load(published))]
    }
}
