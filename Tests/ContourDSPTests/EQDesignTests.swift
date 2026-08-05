import Foundation
import Testing
@testable import ContourDSP

private let sampleRate = 44_100.0

private func responseDB(_ coefficients: BiquadCoefficients,
                        at frequency: Double,
                        sampleRate: Double = sampleRate) -> Double {
    coefficients.magnitudeDB(atNormalizedFrequency: frequency / sampleRate)
}

private func bell(_ frequency: Double, _ gainDB: Double, _ q: Double) -> EQBand {
    EQBand(id: 0, type: .bell, frequency: frequency, gainDB: gainDB, q: q, isEnabled: true)
}

/// A biquad is stable iff its poles lie inside the unit circle, which for real
/// coefficients is |a2| < 1 and |a1| < 1 + a2.
private func expectStable(_ c: BiquadCoefficients,
                          _ note: String,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(c.isFinite, "\(note): coefficients not finite", sourceLocation: sourceLocation)
    #expect(abs(c.a2) < 1.0, "\(note): |a2| = \(abs(c.a2)) >= 1", sourceLocation: sourceLocation)
    #expect(abs(c.a1) < 1 + c.a2,
            "\(note): |a1| = \(abs(c.a1)) >= 1 + a2 = \(1 + c.a2)",
            sourceLocation: sourceLocation)
}

@Suite("EQ coefficient design")
struct EQDesignTests {

    // MARK: - Peaking: gain lands where asked

    @Test("Bell delivers the requested gain at its centre frequency")
    func bellGainAtCentre() {
        for frequency in [50.0, 200, 1_000, 5_000, 12_000, 16_000] {
            for gain in [-15.0, -6, -3, 3, 6, 15] {
                for q in [0.3, 1.0, 4.0, 12.0] {
                    let c = EQDesign.coefficients(for: bell(frequency, gain, q),
                                                  sampleRate: sampleRate)
                    let measured = responseDB(c, at: frequency)
                    #expect(abs(measured - gain) < 0.35,
                            "f=\(frequency) g=\(gain) q=\(q): got \(measured)")
                    expectStable(c, "f=\(frequency) g=\(gain) q=\(q)")
                }
            }
        }
    }

    @Test("A 0 dB bell is exactly identity")
    func unityBellIsIdentity() {
        #expect(EQDesign.coefficients(for: bell(1_000, 0, 1), sampleRate: sampleRate) == .identity)
    }

    @Test("A disabled band is identity regardless of its settings")
    func disabledBandIsIdentity() {
        var band = bell(1_000, 12, 1)
        band.isEnabled = false
        #expect(EQDesign.coefficients(for: band, sampleRate: sampleRate) == .identity)
    }

    // MARK: - Orfanidis: the reason it exists

    /// The design's whole purpose: |H| at Nyquist equals the prescribed G1 the
    /// analog prototype would have. Checking it exercises the entire coefficient
    /// construction, not just the G1 formula.
    @Test("Orfanidis hits its prescribed Nyquist gain")
    func orfanidisNyquistGain() {
        for (frequency, gain, q) in [(12_000.0, 12.0, 4.0),
                                     (10_000.0, -12.0, 6.0),
                                     (16_000.0, 9.0, 2.0),
                                     (8_000.0, 15.0, 1.0)] {
            let w0 = 2 * Double.pi * frequency / sampleRate
            let dw = w0 / q
            let g = pow(10, gain / 20)
            let gb = g.squareRoot()

            let F = abs(g * g - gb * gb)
            let F00 = abs(gb * gb - 1)
            let offset = pow(w0 * w0 - Double.pi * Double.pi, 2)
            let expectedG1 = ((offset + g * g * F00 * Double.pi * Double.pi * dw * dw / F)
                              / (offset + F00 * Double.pi * Double.pi * dw * dw / F)).squareRoot()

            let c = EQDesign.coefficients(for: bell(frequency, gain, q), sampleRate: sampleRate)
            let measured = c.magnitude(atNormalizedFrequency: 0.5)
            #expect(abs(measured - expectedG1) < expectedG1 * 0.02,
                    "f=\(frequency) g=\(gain) q=\(q): got \(measured), expected \(expectedG1)")
        }
    }

    /// RBJ's response is pinned to exactly unity at Nyquist regardless of what
    /// the analog prototype does — algebraically, H(−1) = 1 for the cookbook
    /// peaking form. That is the "cramping" that distorts a high, narrow band.
    ///
    /// The gap is smaller than folklore suggests: for a +12 dB Q=4 bell at
    /// 12 kHz / 44.1 kHz it is ~0.56 dB at Nyquist. It grows with frequency and
    /// with Q, and it is the shape between f₀ and Nyquist — not the Nyquist
    /// value alone — that matters in practice, which is what the sweep below
    /// measures.
    @Test("RBJ cramps at Nyquist where Orfanidis does not")
    func rbjCramping() {
        let frequency = 12_000.0, gain = 12.0, q = 4.0
        let w0 = 2 * Double.pi * frequency / sampleRate

        let orfanidis = EQDesign.orfanidisPeaking(gainDB: gain, w0: w0, q: q)
        let rbj = EQDesign.rbjPeaking(gainDB: gain, w0: w0, q: q)

        let rbjNyquist = rbj.magnitudeDB(atNormalizedFrequency: 0.5)
        let orfanidisNyquist = orfanidis.magnitudeDB(atNormalizedFrequency: 0.5)

        #expect(abs(rbjNyquist) < 0.001,
                "RBJ is algebraically pinned to 0 dB at Nyquist, got \(rbjNyquist)")
        #expect(orfanidisNyquist > 0.25,
                "Orfanidis should carry the analog gain to Nyquist, got \(orfanidisNyquist)")

        // Both must still deliver the requested gain at the centre.
        #expect(abs(responseDB(orfanidis, at: frequency) - gain) < 0.35)
        #expect(abs(responseDB(rbj, at: frequency) - gain) < 0.35)
    }

    @Test("The two designs diverge measurably above the centre frequency")
    func designsDivergeNearNyquist() {
        let frequency = 12_000.0, gain = 12.0, q = 4.0
        let w0 = 2 * Double.pi * frequency / sampleRate
        let orfanidis = EQDesign.orfanidisPeaking(gainDB: gain, w0: w0, q: q)
        let rbj = EQDesign.rbjPeaking(gainDB: gain, w0: w0, q: q)

        var largestGap = 0.0
        var gapFrequency = 0.0
        for hz in stride(from: 200.0, through: 22_000, by: 50) {
            let gap = abs(responseDB(orfanidis, at: hz) - responseDB(rbj, at: hz))
            if gap > largestGap {
                largestGap = gap
                gapFrequency = hz
            }
        }
        #expect(largestGap > 0.5,
                "designs differ by only \(largestGap) dB (at \(gapFrequency) Hz)")
        #expect(gapFrequency > frequency,
                "divergence should be above the centre, found at \(gapFrequency) Hz")
    }

    // MARK: - Cookbook types

    @Test("Low shelf reaches its gain at DC and unity at Nyquist")
    func lowShelf() {
        let band = EQBand(id: 0, type: .lowShelf, frequency: 120,
                          gainDB: 6, q: 0.7, isEnabled: true)
        let c = EQDesign.coefficients(for: band, sampleRate: sampleRate)
        #expect(abs(responseDB(c, at: 1) - 6) < 0.3)
        #expect(abs(c.magnitudeDB(atNormalizedFrequency: 0.5)) < 0.3)
        expectStable(c, "low shelf")
    }

    @Test("High shelf reaches its gain at Nyquist and unity at DC")
    func highShelf() {
        let band = EQBand(id: 0, type: .highShelf, frequency: 8_000,
                          gainDB: -6, q: 0.7, isEnabled: true)
        let c = EQDesign.coefficients(for: band, sampleRate: sampleRate)
        #expect(abs(c.magnitudeDB(atNormalizedFrequency: 0.5) + 6) < 0.5)
        #expect(abs(responseDB(c, at: 1)) < 0.3)
        expectStable(c, "high shelf")
    }

    @Test("Cuts are −3 dB at the corner with Butterworth Q")
    func cutsAtCorner() {
        let q = 1 / 2.0.squareRoot()
        let highPass = EQDesign.coefficients(
            for: EQBand(id: 0, type: .lowCut, frequency: 100, q: q, isEnabled: true),
            sampleRate: sampleRate)
        #expect(abs(responseDB(highPass, at: 100) + 3.01) < 0.2)

        let lowPass = EQDesign.coefficients(
            for: EQBand(id: 0, type: .highCut, frequency: 5_000, q: q, isEnabled: true),
            sampleRate: sampleRate)
        #expect(abs(responseDB(lowPass, at: 5_000) + 3.01) < 0.2)
    }

    @Test("Notch is deep at its centre and flat away from it")
    func notch() {
        let band = EQBand(id: 0, type: .notch, frequency: 1_000, q: 8, isEnabled: true)
        let c = EQDesign.coefficients(for: band, sampleRate: sampleRate)
        #expect(responseDB(c, at: 1_000) < -60)
        #expect(abs(responseDB(c, at: 100)) < 0.3)
        #expect(abs(responseDB(c, at: 10_000)) < 0.3)
    }

    @Test("Cuts ignore the gain parameter")
    func cutsIgnoreGain() {
        var band = EQBand(id: 0, type: .lowCut, frequency: 100, gainDB: 12,
                          q: 0.7, isEnabled: true)
        let withGain = EQDesign.coefficients(for: band, sampleRate: sampleRate)
        band.gainDB = -12
        #expect(withGain == EQDesign.coefficients(for: band, sampleRate: sampleRate))
    }

    // MARK: - Robustness across the whole parameter space

    @Test("Every parameter combination is finite and stable")
    func fullParameterSweep() {
        for rate in [44_100.0, 48_000, 88_200, 96_000] {
            for type in EQBandType.allCases {
                for frequency in [20.0, 100, 1_000, 10_000, 19_500, 20_000] {
                    for gain in [-15.0, 0, 15] {
                        for q in [0.1, 0.7, 18.0] {
                            let band = EQBand(id: 0, type: type, frequency: frequency,
                                              gainDB: gain, q: q, isEnabled: true)
                            expectStable(EQDesign.coefficients(for: band, sampleRate: rate),
                                         "\(type) f=\(frequency) g=\(gain) q=\(q) sr=\(rate)")
                        }
                    }
                }
            }
        }
    }

    /// 20 kHz at 44.1 kHz is legal user input and sits above the design limit.
    @Test("A band above Nyquist is clamped rather than blowing up")
    func aboveNyquist() {
        expectStable(EQDesign.coefficients(for: bell(20_000, 15, 8), sampleRate: sampleRate),
                     "20 kHz at 44.1 kHz")
    }

    // MARK: - Adaptive Q

    @Test("Adaptive Q widens small moves and narrows large ones")
    func adaptiveQ() {
        let small = bell(1_000, 1, 1)
        let large = bell(1_000, 15, 1)
        #expect(EQDesign.effectiveQ(for: small, adaptiveQ: false) == 1.0)
        #expect(EQDesign.effectiveQ(for: small, adaptiveQ: true)
                < EQDesign.effectiveQ(for: large, adaptiveQ: true))
    }

    @Test("Adaptive Q does not touch cuts, which have no gain")
    func adaptiveQIgnoresCuts() {
        let band = EQBand(id: 0, type: .lowCut, frequency: 100, gainDB: 15,
                          q: 2, isEnabled: true)
        #expect(EQDesign.effectiveQ(for: band, adaptiveQ: true) == 2)
    }
}

@Suite("Shelf Q range")
struct ShelfQRangeTests {

    /// The reason the control stops where it does: inside this range a shelf is
    /// monotonic, so a "+6 dB" shelf delivers at most +6 dB and never dips below
    /// unity on the other side of the corner.
    @Test("Shelves never overshoot within the editable Q range")
    func shelvesDoNotOvershoot() {
        for type in [EQBandType.lowShelf, .highShelf] {
            let range = type.editableQRange
            for gain in [-15.0, -6, 6, 15] {
                for q in [range.lowerBound, 0.3, 0.5, range.upperBound] {
                    for frequency in [100.0, 1_000, 6_000] {
                        let band = EQBand(id: 0, type: type, frequency: frequency,
                                          gainDB: gain, q: q, isEnabled: true)
                        let c = EQDesign.coefficients(for: band, sampleRate: sampleRate)
                        var high = -99.0, low = 99.0
                        for hz in stride(from: 20.0, through: 20_000, by: 20) {
                            let db = c.magnitudeDB(atNormalizedFrequency: hz / sampleRate)
                            high = Swift.max(high, db)
                            low = Swift.min(low, db)
                        }
                        let note = "\(type) g=\(gain) q=\(q) f=\(frequency)"
                        if gain > 0 {
                            #expect(high <= gain + 0.15, "\(note): overshoot to \(high)")
                            #expect(low >= -0.15, "\(note): dipped to \(low)")
                        } else {
                            #expect(low >= gain - 0.15, "\(note): undershoot to \(low)")
                            #expect(high <= 0.15, "\(note): peaked to \(high)")
                        }
                    }
                }
            }
        }
    }

    /// Above the limit the resonance is real, which is why the control excludes
    /// it rather than the design forbidding it.
    @Test("Shelves above the editable range do resonate")
    func shelvesAboveRangeResonate() {
        let band = EQBand(id: 0, type: .highShelf, frequency: 8_000,
                          gainDB: 6, q: 8, isEnabled: true)
        let c = EQDesign.coefficients(for: band, sampleRate: sampleRate)
        var high = -99.0, low = 99.0
        for hz in stride(from: 20.0, through: 20_000, by: 20) {
            let db = c.magnitudeDB(atNormalizedFrequency: hz / sampleRate)
            high = Swift.max(high, db)
            low = Swift.min(low, db)
        }
        #expect(high > 8, "expected overshoot well past +6 dB, got \(high)")
        #expect(low < -5, "expected a matching dip, got \(low)")
    }

    /// Imports must survive. A curve carrying a resonant shelf keeps its value.
    @Test("An imported resonant shelf keeps its Q")
    func importedShelfKeepsItsQ() {
        let band = EQBand(id: 0, type: .lowShelf, frequency: 120,
                          gainDB: 4, q: 3, isEnabled: true)
        #expect(band.editableQRange.upperBound >= 3)
        #expect(band.clamped.q == 3)
    }

    @Test("Bells and cuts keep the full Q range")
    func bellsKeepFullRange() {
        for type in [EQBandType.bell, .lowCut, .highCut, .notch] {
            #expect(type.editableQRange == EQBand.qRange)
        }
    }
}
