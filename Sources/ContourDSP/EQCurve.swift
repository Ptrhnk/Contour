import Accelerate
import Foundation

/// Cached magnitude response on a fixed log-frequency grid.
///
/// Each band's response is stored separately in dB. The composite is their sum,
/// because dB adds — so dragging one band recomputes one eighth of the work and
/// the total is a single `vDSP_vaddD`.
public final class EQCurveCache {

    public let frequencies: [Double]
    public private(set) var composite: [Double]

    private var bandMagnitudes: [[Double]]
    private var sampleRate: Double
    private let pointCount: Int

    public init(pointCount: Int = 256,
                range: ClosedRange<Double> = 20...20_000,
                bandCount: Int = EQBand.count,
                sampleRate: Double = 44_100) {
        self.pointCount = pointCount
        self.sampleRate = sampleRate
        let logLow = log10(range.lowerBound)
        let logHigh = log10(range.upperBound)
        frequencies = (0..<pointCount).map { index in
            let t = Double(index) / Double(pointCount - 1)
            return pow(10, logLow + t * (logHigh - logLow))
        }
        bandMagnitudes = Array(repeating: Array(repeating: 0, count: pointCount),
                               count: bandCount)
        composite = Array(repeating: 0, count: pointCount)
    }

    /// Recomputes everything. Call on sample-rate change or a whole-preset load.
    public func rebuild(bands: [EQBand], adaptiveQ: Bool, sampleRate: Double? = nil) {
        if let sampleRate { self.sampleRate = sampleRate }
        for (index, band) in bands.enumerated() where index < bandMagnitudes.count {
            recompute(index, band: band, adaptiveQ: adaptiveQ)
        }
        sum()
    }

    /// The drag path: one band changed, so only its row is recomputed.
    public func update(bandAt index: Int, band: EQBand, adaptiveQ: Bool) {
        guard index < bandMagnitudes.count else { return }
        recompute(index, band: band, adaptiveQ: adaptiveQ)
        sum()
    }

    /// Peak boost of the composite curve, for the one-click input trim in §5.5.
    public var maximumBoostDB: Double { composite.max() ?? 0 }

    public func compositeDB(atIndex index: Int) -> Double {
        guard index >= 0, index < composite.count else { return 0 }
        return composite[index]
    }

    /// Peak boost of a band set without building a cache.
    ///
    /// Used by auto-trim, which needs the answer on every parameter change but
    /// has no curve view to borrow one from. Evaluated on a coarser grid than
    /// the display — the peak of a smooth response does not need 256 points.
    public static func maximumBoostDB(bands: [EQBand],
                                      adaptiveQ: Bool,
                                      sampleRate: Double,
                                      pointCount: Int = 96) -> Double {
        guard sampleRate > 0, !bands.isEmpty else { return 0 }
        let coefficients = bands.map {
            EQDesign.coefficients(for: $0, sampleRate: sampleRate, adaptiveQ: adaptiveQ)
        }
        let logLow = log10(20.0)
        let logHigh = log10(min(20_000.0, sampleRate / 2 * 0.99))
        var peak = 0.0
        for index in 0..<pointCount {
            let t = Double(index) / Double(pointCount - 1)
            let frequency = pow(10, logLow + t * (logHigh - logLow))
            let normalized = frequency / sampleRate
            var total = 0.0
            for section in coefficients {
                let db = section.magnitudeDB(atNormalizedFrequency: normalized)
                if db.isFinite { total += db }
            }
            if total > peak { peak = total }
        }
        return peak
    }

    private func recompute(_ index: Int, band: EQBand, adaptiveQ: Bool) {
        let coefficients = EQDesign.coefficients(for: band,
                                                 sampleRate: sampleRate,
                                                 adaptiveQ: adaptiveQ)
        let nyquist = sampleRate / 2
        for (point, frequency) in frequencies.enumerated() {
            guard frequency < nyquist else {
                bandMagnitudes[index][point] = 0
                continue
            }
            let db = coefficients.magnitudeDB(atNormalizedFrequency: frequency / sampleRate)
            bandMagnitudes[index][point] = db.isFinite ? db : -120
        }
    }

    private func sum() {
        let count = vDSP_Length(pointCount)
        var total = [Double](repeating: 0, count: pointCount)
        for row in bandMagnitudes {
            row.withUnsafeBufferPointer { source in
                total.withUnsafeMutableBufferPointer { destination in
                    vDSP_vaddD(destination.baseAddress!, 1,
                               source.baseAddress!, 1,
                               destination.baseAddress!, 1,
                               count)
                }
            }
        }
        composite = total
    }
}
