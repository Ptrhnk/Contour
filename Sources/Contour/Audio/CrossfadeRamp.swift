import Accelerate

/// Ramped dry/wet crossfade, used by the master bypass.
///
/// Linear rather than equal-power on purpose: the two sides are the *same*
/// signal, one processed, so they are correlated. An equal-power curve would
/// bulge by about 3 dB through the middle of the fade, which on a bypass switch
/// reads as a bump rather than a comparison.
///
/// One buffer to reach the target, matching `GainRamp` — 10.7 ms at 512 frames
/// and 48 kHz, short enough to feel instant and long enough not to click.
final class CrossfadeRamp: @unchecked Sendable {

    /// 1 = fully processed. Touched only by the realtime thread.
    private var current: Float

    init(initial: Float = 1) {
        current = initial
    }

    func reset(to value: Float) {
        current = value
    }

    /// Realtime thread. Mixes `dry` into `wet` in place; `dry` is left scaled
    /// and should be treated as spent.
    @inline(__always)
    func apply(target: Float,
               wetL: UnsafeMutablePointer<Float>,
               wetR: UnsafeMutablePointer<Float>,
               dryL: UnsafeMutablePointer<Float>,
               dryR: UnsafeMutablePointer<Float>,
               frames: Int) {
        let count = vDSP_Length(frames)

        if abs(target - current) < 1e-6 {
            current = target
            // Fully processed is the common case, and then the dry copy is not
            // wanted at all — no mix, no traffic over it.
            if target >= 1 - 1e-6 { return }
            if target <= 1e-6 {
                memcpy(wetL, dryL, frames * MemoryLayout<Float>.size)
                memcpy(wetR, dryR, frames * MemoryLayout<Float>.size)
                return
            }
            var wet = target
            var dry = 1 - target
            vDSP_vsmul(wetL, 1, &wet, wetL, 1, count)
            vDSP_vsmul(wetR, 1, &wet, wetR, 1, count)
            vDSP_vsma(dryL, 1, &dry, wetL, 1, wetL, 1, count)
            vDSP_vsma(dryR, 1, &dry, wetR, 1, wetR, 1, count)
            return
        }

        let wetStep = (target - current) / Float(frames)
        let dryStep = -wetStep
        // vDSP_vrampmul advances `start`, so every call needs its own copy.
        var start = current
        var increment = wetStep
        vDSP_vrampmul(wetL, 1, &start, &increment, wetL, 1, count)
        start = current
        increment = wetStep
        vDSP_vrampmul(wetR, 1, &start, &increment, wetR, 1, count)

        start = 1 - current
        increment = dryStep
        vDSP_vrampmul(dryL, 1, &start, &increment, dryL, 1, count)
        start = 1 - current
        increment = dryStep
        vDSP_vrampmul(dryR, 1, &start, &increment, dryR, 1, count)

        vDSP_vadd(wetL, 1, dryL, 1, wetL, 1, count)
        vDSP_vadd(wetR, 1, dryR, 1, wetR, 1, count)
        current = target
    }
}

/// Pre-allocated dry copy for the crossfade. One stereo pair is enough: chain A
/// is finished with before chain B starts.
final class DryScratch: @unchecked Sendable {

    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deinitialize(count: capacity)
        left.deallocate()
        right.deinitialize(count: capacity)
        right.deallocate()
    }
}
