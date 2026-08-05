import Foundation

/// Coefficient design for one band.
///
/// Bells use Orfanidis's prescribed-Nyquist-gain design; everything else uses
/// the RBJ cookbook. See `orfanidisPeaking` for why.
public enum EQDesign {

    /// Highest fraction of the sample rate a band may sit at. The design
    /// equations degenerate as ω₀ → π.
    static let maximumNormalizedFrequency = 0.497

    public static func coefficients(for band: EQBand,
                                    sampleRate: Double,
                                    adaptiveQ: Bool = false) -> BiquadCoefficients {
        guard band.isEnabled, sampleRate > 0 else { return .identity }

        let band = band.clamped
        let nyquist = sampleRate / 2
        let frequency = min(band.frequency, sampleRate * maximumNormalizedFrequency)
        guard frequency > 0, frequency < nyquist else { return .identity }

        let q = effectiveQ(for: band, adaptiveQ: adaptiveQ)
        let w0 = 2 * Double.pi * frequency / sampleRate

        let designed: BiquadCoefficients
        switch band.type {
        case .bell:
            designed = orfanidisPeaking(gainDB: band.gainDB, w0: w0, q: q)
        case .lowShelf:
            designed = lowShelf(gainDB: band.gainDB, w0: w0, q: q)
        case .highShelf:
            designed = highShelf(gainDB: band.gainDB, w0: w0, q: q)
        case .lowCut:
            designed = highPass(w0: w0, q: q)
        case .highCut:
            designed = lowPass(w0: w0, q: q)
        case .notch:
            designed = notch(w0: w0, q: q)
        }
        // A NaN reaching the cascade would poison the filter state permanently.
        return designed.isFinite ? designed : .identity
    }

    /// Q rises with |gain| so small moves stay broad and large ones stay surgical.
    static func effectiveQ(for band: EQBand, adaptiveQ: Bool) -> Double {
        guard adaptiveQ, band.type.usesGain else { return band.q }
        let normalized = min(abs(band.gainDB) / EQBand.gainRange.upperBound, 1)
        return min(band.q * (1 + normalized), EQBand.qRange.upperBound)
    }

    // MARK: - Orfanidis peaking

    /// Peaking EQ whose response matches the analog prototype at Nyquist.
    ///
    /// The plain bilinear transform forces the digital response to a fixed value
    /// at Nyquist, which "cramps" a high-Q bell placed near the top of the band:
    /// a narrow notch at 10–12 kHz at 44.1 kHz comes out shifted and the wrong
    /// width — exactly the correction a planar headphone needs. Orfanidis solves
    /// for the Nyquist gain G1 the analog filter would have and designs to it.
    ///
    /// Transcribed from `peq.m` in Sophocles J. Orfanidis, "Digital Parametric
    /// Equalizer Design with Prescribed Nyquist-Frequency Gain", JAES vol. 45
    /// no. 6, pp. 444–455, June 1997.
    ///
    /// - Parameters:
    ///   - w0: centre frequency in radians per sample
    ///   - q: Q, converted to bandwidth as Δω = ω₀ / Q
    static func orfanidisPeaking(gainDB: Double, w0: Double, q: Double) -> BiquadCoefficients {
        let g0 = 1.0                                  // reference gain
        let g = pow(10, gainDB / 20)                  // peak gain
        let gb = (g0 * g).squareRoot()                // bandwidth gain, the −3 dB-equivalent point
        let dw = w0 / q

        // At unity gain every difference below is zero and F divides by zero.
        guard abs(g - g0) > 1e-9, abs(g - gb) > 1e-12 else { return .identity }

        let pi = Double.pi
        let F = abs(g * g - gb * gb)
        let G00 = abs(g * g - g0 * g0)
        let F00 = abs(gb * gb - g0 * g0)

        // G1: the gain the analog prototype has at Nyquist.
        let offset = pow(w0 * w0 - pi * pi, 2)
        let num = g0 * g0 * offset + g * g * F00 * pi * pi * dw * dw / F
        let den = offset + F00 * pi * pi * dw * dw / F
        guard den > 0 else { return .identity }
        let g1 = (num / den).squareRoot()

        let G01 = abs(g * g - g0 * g1)
        let G11 = abs(g * g - g1 * g1)
        let F01 = abs(gb * gb - g0 * g1)
        let F11 = abs(gb * gb - g1 * g1)

        guard G00 > 0, F11 > 0 else { return .identity }

        let W2 = (G11 / G00).squareRoot() * pow(tan(w0 / 2), 2)
        let DW = (1 + (F00 / F11).squareRoot() * W2) * tan(dw / 2)

        let C = F11 * DW * DW - 2 * W2 * (F01 - (F00 * F11).squareRoot())
        let D = 2 * W2 * (G01 - (G00 * G11).squareRoot())

        let A = ((C + D) / F).squareRoot()
        let B = ((g * g * C + gb * gb * D) / F).squareRoot()

        let scale = 1 + W2 + A
        guard scale != 0 else { return .identity }

        return BiquadCoefficients(
            b0: (g1 + g0 * W2 + B) / scale,
            b1: -2 * (g1 - g0 * W2) / scale,
            b2: (g1 - B + g0 * W2) / scale,
            a1: -2 * (1 - W2) / scale,
            a2: (1 + W2 - A) / scale)
    }

    /// RBJ peaking, kept for A/B against the Orfanidis design in tests.
    static func rbjPeaking(gainDB: Double, w0: Double, q: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let alpha = sin(w0) / (2 * q)
        return BiquadCoefficients(b0: 1 + alpha * a,
                                  b1: -2 * cos(w0),
                                  b2: 1 - alpha * a,
                                  a0: 1 + alpha / a,
                                  a1: -2 * cos(w0),
                                  a2: 1 - alpha / a)
    }

    // MARK: - RBJ cookbook

    static func lowShelf(gainDB: Double, w0: Double, q: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
        return BiquadCoefficients(
            b0: a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha),
            b1: 2 * a * ((a - 1) - (a + 1) * cosw),
            b2: a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha),
            a0: (a + 1) + (a - 1) * cosw + twoSqrtAAlpha,
            a1: -2 * ((a - 1) + (a + 1) * cosw),
            a2: (a + 1) + (a - 1) * cosw - twoSqrtAAlpha)
    }

    static func highShelf(gainDB: Double, w0: Double, q: Double) -> BiquadCoefficients {
        let a = pow(10, gainDB / 40)
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
        return BiquadCoefficients(
            b0: a * ((a + 1) + (a - 1) * cosw + twoSqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cosw),
            b2: a * ((a + 1) + (a - 1) * cosw - twoSqrtAAlpha),
            a0: (a + 1) - (a - 1) * cosw + twoSqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cosw),
            a2: (a + 1) - (a - 1) * cosw - twoSqrtAAlpha)
    }

    static func highPass(w0: Double, q: Double) -> BiquadCoefficients {
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return BiquadCoefficients(b0: (1 + cosw) / 2,
                                  b1: -(1 + cosw),
                                  b2: (1 + cosw) / 2,
                                  a0: 1 + alpha,
                                  a1: -2 * cosw,
                                  a2: 1 - alpha)
    }

    static func lowPass(w0: Double, q: Double) -> BiquadCoefficients {
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return BiquadCoefficients(b0: (1 - cosw) / 2,
                                  b1: 1 - cosw,
                                  b2: (1 - cosw) / 2,
                                  a0: 1 + alpha,
                                  a1: -2 * cosw,
                                  a2: 1 - alpha)
    }

    static func notch(w0: Double, q: Double) -> BiquadCoefficients {
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return BiquadCoefficients(b0: 1,
                                  b1: -2 * cosw,
                                  b2: 1,
                                  a0: 1 + alpha,
                                  a1: -2 * cosw,
                                  a2: 1 - alpha)
    }
}
