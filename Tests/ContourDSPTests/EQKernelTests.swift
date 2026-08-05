import Foundation
import Testing
@testable import ContourDSP

private let sampleRate = 44_100.0

/// Drives a steady sine through the kernel and measures the settled output
/// amplitude.
private func measuredGainDB(_ kernel: EQKernel, at frequency: Double) -> Double {
    let settle = 2_048
    let total = settle + 4_096
    var left = [Float](repeating: 0, count: total)
    var right = [Float](repeating: 0, count: total)
    for n in 0..<total {
        let value = Float(sin(2 * .pi * frequency * Double(n) / sampleRate))
        left[n] = value
        right[n] = value
    }

    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var offset = 0
            while offset < total {
                let block = min(kernel.maximumFrames, total - offset)
                kernel.process(left: l.baseAddress! + offset,
                               right: r.baseAddress! + offset,
                               frames: block)
                offset += block
            }
        }
    }

    // A pure sine's peak is its amplitude.
    let peak = left[settle..<total].reduce(Float(0)) { max($0, abs($1)) }
    return 20 * log10(Double(peak))
}

private func makeKernel(_ bands: [EQBand]) -> EQKernel {
    let kernel = EQKernel(sections: EQBand.count, channels: 2,
                          maximumFrames: 512, sampleRate: sampleRate)
    kernel.setCoefficients(bands.map {
        EQDesign.coefficients(for: $0, sampleRate: sampleRate)
    })
    kernel.reset()
    return kernel
}

private func disabledBands() -> [EQBand] {
    (0..<EQBand.count).map { EQBand(id: $0, type: .bell, frequency: 1_000) }
}

/// These verify that what vDSP actually computes matches what the coefficient
/// maths predicts. Getting vDSP's `a1`/`a2` sign convention backwards yields a
/// filter that is stable and plausible-sounding but wrong, so it has to be
/// measured rather than reasoned about.
@Suite("EQ kernel")
struct EQKernelTests {

    @Test("Measured response matches the predicted response")
    func measuredMatchesPredicted() {
        for (frequency, gain, q) in [(1_000.0, 9.0, 1.0),
                                     (200.0, -9.0, 2.0),
                                     (12_000.0, 12.0, 4.0)] {
            var bands = disabledBands()
            bands[0] = EQBand(id: 0, type: .bell, frequency: frequency,
                              gainDB: gain, q: q, isEnabled: true)

            let predicted = EQDesign
                .coefficients(for: bands[0], sampleRate: sampleRate)
                .magnitudeDB(atNormalizedFrequency: frequency / sampleRate)
            let measured = measuredGainDB(makeKernel(bands), at: frequency)

            #expect(abs(measured - predicted) < 0.5,
                    "f=\(frequency) g=\(gain) q=\(q): measured \(measured), predicted \(predicted)")
        }
    }

    @Test("All bands disabled passes audio through unchanged")
    func disabledPassesThrough() {
        let kernel = makeKernel(disabledBands())
        for frequency in [100.0, 1_000, 10_000] {
            let measured = measuredGainDB(kernel, at: frequency)
            #expect(abs(measured) < 0.05, "\(frequency) Hz: got \(measured) dB")
        }
    }

    /// Cascaded sections multiply, so their dB responses add.
    @Test("Cascaded bands sum in decibels")
    func cascadeSums() {
        var bands = disabledBands()
        bands[0] = EQBand(id: 0, type: .bell, frequency: 1_000, gainDB: 6, q: 1, isEnabled: true)
        bands[1] = EQBand(id: 1, type: .bell, frequency: 1_000, gainDB: 4, q: 1, isEnabled: true)
        let measured = measuredGainDB(makeKernel(bands), at: 1_000)
        #expect(abs(measured - 10) < 0.5, "got \(measured)")
    }

    @Test("Extreme settings never produce non-finite output")
    func extremeSettingsStayFinite() {
        let bands = EQBand.defaultBands.map {
            var band = $0
            band.isEnabled = true
            band.gainDB = 15
            band.q = 18
            return band
        }
        let kernel = makeKernel(bands)
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        for n in 0..<512 {
            left[n] = Float.random(in: -1...1)
            right[n] = left[n]
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                for _ in 0..<20 {
                    kernel.process(left: l.baseAddress!, right: r.baseAddress!, frames: 512)
                }
            }
        }
        #expect(left.allSatisfy { $0.isFinite })
    }

    @Test("Both channels are filtered identically")
    func channelsMatch() {
        var bands = disabledBands()
        bands[0] = EQBand(id: 0, type: .bell, frequency: 1_000, gainDB: 9, q: 1, isEnabled: true)
        let kernel = makeKernel(bands)

        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        for n in 0..<512 {
            left[n] = Float(sin(2 * .pi * 1_000 * Double(n) / sampleRate))
            right[n] = left[n]
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                kernel.process(left: l.baseAddress!, right: r.baseAddress!, frames: 512)
            }
        }
        #expect(zip(left, right).allSatisfy { abs($0 - $1) < 1e-6 })
    }
}

@Suite("EQ curve cache")
struct EQCurveCacheTests {

    @Test("Composite equals the sum of the individual band responses")
    func compositeIsSum() {
        var bands = EQBand.defaultBands
        bands[2].gainDB = 6
        bands[2].isEnabled = true
        bands[4].gainDB = -4
        bands[4].isEnabled = true

        let cache = EQCurveCache(sampleRate: sampleRate)
        cache.rebuild(bands: bands, adaptiveQ: false)

        for (index, frequency) in cache.frequencies.enumerated() where frequency < 20_000 {
            let expected = bands.reduce(0.0) { total, band in
                total + EQDesign.coefficients(for: band, sampleRate: sampleRate)
                    .magnitudeDB(atNormalizedFrequency: frequency / sampleRate)
            }
            #expect(abs(cache.compositeDB(atIndex: index) - expected) < 0.001)
        }
    }

    /// The drag path must give the same answer as a full rebuild.
    @Test("Incremental single-band update matches a full rebuild")
    func incrementalMatchesRebuild() {
        var bands = EQBand.defaultBands
        let incremental = EQCurveCache(sampleRate: sampleRate)
        incremental.rebuild(bands: bands, adaptiveQ: false)

        bands[3].gainDB = 11
        bands[3].q = 5
        incremental.update(bandAt: 3, band: bands[3], adaptiveQ: false)

        let full = EQCurveCache(sampleRate: sampleRate)
        full.rebuild(bands: bands, adaptiveQ: false)

        for index in 0..<full.frequencies.count {
            #expect(abs(incremental.compositeDB(atIndex: index)
                        - full.compositeDB(atIndex: index)) < 1e-9)
        }
    }

    @Test("Maximum boost finds the peak used by the input-trim action")
    func maximumBoost() {
        var bands = EQBand.defaultBands
        bands[3] = EQBand(id: 3, type: .bell, frequency: 1_000, gainDB: 9, q: 1, isEnabled: true)
        let cache = EQCurveCache(sampleRate: sampleRate)
        cache.rebuild(bands: bands, adaptiveQ: false)
        #expect(abs(cache.maximumBoostDB - 9) < 0.3, "got \(cache.maximumBoostDB)")
    }
}
