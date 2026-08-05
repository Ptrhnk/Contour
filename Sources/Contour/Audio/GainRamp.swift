import Accelerate

/// Per-block linear gain ramp.
///
/// Needed once presets can change level: applying a new scalar gain between one
/// callback and the next is a step discontinuity, which is an audible click.
/// Ramping across the block spreads it over ~11 ms at 512 frames / 44.1 kHz,
/// which is inaudible and costs one extra vDSP call only while the gain is
/// actually moving.
final class GainRamp: @unchecked Sendable {

    /// Touched only by the realtime thread.
    private var current: Float

    init(initial: Float = 1) {
        current = initial
    }

    func reset(to value: Float) {
        current = value
    }

    /// Realtime thread. In-place stereo scaling.
    @inline(__always)
    func apply(target: Float,
               left: UnsafeMutablePointer<Float>,
               right: UnsafeMutablePointer<Float>,
               frames: Int) {
        let count = vDSP_Length(frames)

        if abs(target - current) < 1e-6 {
            var gain = target
            vDSP_vsmul(left, 1, &gain, left, 1, count)
            vDSP_vsmul(right, 1, &gain, right, 1, count)
            current = target
            return
        }

        let step = (target - current) / Float(frames)
        // vDSP_vrampmul advances `start` as it goes, so each channel needs its own.
        var start = current
        var increment = step
        vDSP_vrampmul(left, 1, &start, &increment, left, 1, count)
        start = current
        increment = step
        vDSP_vrampmul(right, 1, &start, &increment, right, 1, count)
        current = target
    }
}
