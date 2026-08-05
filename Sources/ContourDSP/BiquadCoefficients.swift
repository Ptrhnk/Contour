import Foundation

/// One normalised biquad section: `a0` has been divided out.
///
/// The difference equation matches vDSP's convention, which is what lets these
/// be handed to `vDSP_biquadm` unchanged:
///
///     y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Passthrough. `a1` and `a2` are zero, so an identity section carries no
    /// recursive state and cannot accumulate denormals.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Divides through by `a0`.
    public init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public var isFinite: Bool {
        b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
    }

    /// |H(e^{jω})| at a normalised frequency in cycles per sample (0…0.5).
    public func magnitude(atNormalizedFrequency frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)

        // e^{-jω} = cos ω − j sin ω
        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImaginary = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImaginary = -(a1 * sin1 + a2 * sin2)

        let numerator = (numeratorReal * numeratorReal
                         + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal
                           + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0 else { return .infinity }
        return numerator / denominator
    }

    public func magnitudeDB(atNormalizedFrequency frequency: Double) -> Double {
        let magnitude = magnitude(atNormalizedFrequency: frequency)
        return magnitude > 0 ? 20 * log10(magnitude) : -.infinity
    }

    /// Flattened as vDSP wants it: b0, b1, b2, a1, a2.
    public var vDSPCoefficients: [Double] { [b0, b1, b2, a1, a2] }
}
