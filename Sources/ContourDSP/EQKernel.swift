import Accelerate
import Foundation

/// The realtime side of the EQ: a fixed cascade of stereo biquads.
///
/// The section count is fixed at construction and disabled bands are fed
/// identity coefficients rather than being removed. That trades a little idle
/// work — an identity section has `a1 = a2 = 0`, so it is a copy with no
/// recursion and no denormal risk — for two things worth more here: coefficient
/// changes always ramp through `vDSP_biquadm_SetTargetsDoubleD`, so *enabling*
/// a band fades in instead of clicking, and the setup never has to be
/// reallocated while audio is running.
public final class EQKernel: @unchecked Sendable {

    public let sections: Int
    public let channels: Int
    public let maximumFrames: Int
    public private(set) var sampleRate: Double

    private var setup: vDSP_biquadm_SetupD?
    /// Interleaved per channel: [channel][section][5].
    private var coefficientStorage: [Double]
    private var inputScratch: UnsafeMutablePointer<Double>
    private var outputScratch: UnsafeMutablePointer<Double>
    private var inputPointers: UnsafeMutablePointer<UnsafePointer<Double>>
    private var outputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Double>>

    /// ~20 ms at 44.1 kHz. `vDSP` moves each coefficient toward its target by
    /// this fraction of the remaining distance per frame.
    private static let interpolationRate = 0.995
    private static let interpolationThreshold = 1e-9

    public init(sections: Int = EQBand.count,
                channels: Int = 2,
                maximumFrames: Int,
                sampleRate: Double = 44_100) {
        self.sections = sections
        self.channels = channels
        self.maximumFrames = maximumFrames
        self.sampleRate = sampleRate

        coefficientStorage = Self.flatten(
            Array(repeating: BiquadCoefficients.identity, count: sections),
            sections: sections,
            channels: channels)

        let total = maximumFrames * channels
        inputScratch = .allocate(capacity: total)
        inputScratch.initialize(repeating: 0, count: total)
        outputScratch = .allocate(capacity: total)
        outputScratch.initialize(repeating: 0, count: total)

        inputPointers = .allocate(capacity: channels)
        outputPointers = .allocate(capacity: channels)
        for channel in 0..<channels {
            inputPointers[channel] = UnsafePointer(inputScratch + channel * maximumFrames)
            outputPointers[channel] = outputScratch + channel * maximumFrames
        }

        setup = coefficientStorage.withUnsafeBufferPointer {
            vDSP_biquadm_CreateSetupD($0.baseAddress!,
                                      vDSP_Length(sections),
                                      vDSP_Length(channels))
        }
    }

    deinit {
        if let setup { vDSP_biquadm_DestroySetupD(setup) }
        inputScratch.deallocate()
        outputScratch.deallocate()
        inputPointers.deallocate()
        outputPointers.deallocate()
    }

    // MARK: - Coefficients

    /// vDSP's coefficient buffer is **section-major**: all channels of section 0,
    /// then all channels of section 1, and so on. Laying it out channel-major
    /// instead silently gives each channel every *other* band, applied twice —
    /// a stable filter with double the requested gain. `EQKernelTests` measures
    /// this rather than trusting the ordering.
    public static func flatten(_ coefficients: [BiquadCoefficients],
                               sections: Int,
                               channels: Int) -> [Double] {
        var flat = [Double]()
        flat.reserveCapacity(sections * channels * 5)
        for index in 0..<sections {
            let section = index < coefficients.count ? coefficients[index] : .identity
            let values = section.vDSPCoefficients
            for _ in 0..<channels {
                flat.append(contentsOf: values)
            }
        }
        return flat
    }

    /// Ramped, and the realtime-safe form: the caller owns an already-flattened
    /// buffer, so nothing is allocated here.
    public func setTargets(raw coefficients: UnsafePointer<Double>) {
        guard let setup else { return }
        vDSP_biquadm_SetTargetsDoubleD(setup,
                                       coefficients,
                                       Self.interpolationRate,
                                       Self.interpolationThreshold,
                                       0, 0,
                                       vDSP_Length(sections),
                                       vDSP_Length(channels))
    }

    /// Convenience for tests and setup. Allocates — never call on the audio thread.
    public func setTargets(_ coefficients: [BiquadCoefficients]) {
        coefficientStorage = Self.flatten(coefficients, sections: sections, channels: channels)
        coefficientStorage.withUnsafeBufferPointer { setTargets(raw: $0.baseAddress!) }
    }

    /// Immediate, no ramp. For construction and sample-rate rebuilds only.
    public func setCoefficients(_ coefficients: [BiquadCoefficients]) {
        guard let setup else { return }
        coefficientStorage = Self.flatten(coefficients, sections: sections, channels: channels)
        coefficientStorage.withUnsafeBufferPointer {
            vDSP_biquadm_SetCoefficientsDoubleD(setup,
                                                $0.baseAddress!,
                                                0, 0,
                                                vDSP_Length(sections),
                                                vDSP_Length(channels))
        }
    }

    public func reset() {
        if let setup { vDSP_biquadm_ResetStateD(setup) }
    }

    public func updateSampleRate(_ newValue: Double) {
        sampleRate = newValue
    }

    // MARK: - Processing

    /// In-place stereo processing. Realtime thread; no allocation.
    public func process(left: UnsafeMutablePointer<Float>,
                        right: UnsafeMutablePointer<Float>,
                        frames: Int) {
        guard let setup, frames > 0, frames <= maximumFrames, channels == 2 else { return }
        let count = vDSP_Length(frames)

        vDSP_vspdp(left, 1, inputScratch, 1, count)
        vDSP_vspdp(right, 1, inputScratch + maximumFrames, 1, count)

        vDSP_biquadmD(setup, inputPointers, 1, outputPointers, 1, count)

        vDSP_vdpsp(outputScratch, 1, left, 1, count)
        vDSP_vdpsp(outputScratch + maximumFrames, 1, right, 1, count)
    }
}
