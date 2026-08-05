#ifndef CONTOUR_ATOMICS_H
#define CONTOUR_ATOMICS_H

#include <stdatomic.h>
#include <stdint.h>

/// Minimal atomic used to publish the triple buffer's read slot.
/// Swift's `Synchronization.Atomic` is macOS 15+; Contour targets 14.4, and
/// pulling in swift-atomics for one integer is not worth a dependency.
typedef struct {
    _Atomic uint32_t value;
} ContourAtomicUInt32;

static inline void contour_atomic_init(ContourAtomicUInt32 *slot, uint32_t value) {
    atomic_init(&slot->value, value);
}

/// Release: everything written to the slot before this is visible to a reader
/// that observes this index.
static inline void contour_atomic_store(ContourAtomicUInt32 *slot, uint32_t value) {
    atomic_store_explicit(&slot->value, value, memory_order_release);
}

/// Acquire: pairs with the store above. Lock-free and wait-free on arm64,
/// which is what makes it legal on the realtime thread.
static inline uint32_t contour_atomic_load(const ContourAtomicUInt32 *slot) {
    return atomic_load_explicit(&slot->value, memory_order_acquire);
}

#endif /* CONTOUR_ATOMICS_H */
