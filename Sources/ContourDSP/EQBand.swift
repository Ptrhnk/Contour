import Foundation

public enum EQBandType: String, Codable, CaseIterable, Sendable {
    case lowCut
    case lowShelf
    case bell
    case highShelf
    case highCut
    case notch

    public var title: String {
        switch self {
        case .lowCut: "Low Cut"
        case .lowShelf: "Low Shelf"
        case .bell: "Bell"
        case .highShelf: "High Shelf"
        case .highCut: "High Cut"
        case .notch: "Notch"
        }
    }

    public var symbol: String {
        switch self {
        case .lowCut: "chevron.up.forward"
        case .lowShelf: "square.righthalf.filled"
        case .bell: "bell"
        case .highShelf: "square.lefthalf.filled"
        case .highCut: "chevron.up.backward"
        case .notch: "arrow.down.to.line"
        }
    }

    /// Q the UI will let you dial in, which is narrower than what the design
    /// accepts.
    ///
    /// An RBJ shelf becomes resonant above Q = 1/√2: it overshoots the
    /// requested gain and dips by a matching amount on the far side of the
    /// corner. A "+6 dB" shelf at Q = 18 actually swings +25 to −19 dB. That is
    /// correct behaviour for the filter, and almost never what anyone wants, so
    /// the control stops at the point where the shelf is steepest without
    /// overshooting. Bells and cuts keep the full range, where high Q is the
    /// entire point.
    public var editableQRange: ClosedRange<Double> {
        switch self {
        case .lowShelf, .highShelf: 0.1...(1 / 2.0.squareRoot())
        case .bell, .lowCut, .highCut, .notch: EQBand.qRange
        }
    }

    /// Cuts and notches have no gain parameter.
    public var usesGain: Bool {
        switch self {
        case .lowCut, .highCut, .notch: false
        case .lowShelf, .bell, .highShelf: true
        }
    }
}

public struct EQBand: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var type: EQBandType
    /// Hz.
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    /// Disabled bands are rendered as identity sections rather than being
    /// removed, so toggling one ramps instead of clicking. See `EQKernel`.
    public var isEnabled: Bool

    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let gainRange: ClosedRange<Double> = -15...15
    public static let qRange: ClosedRange<Double> = 0.1...18

    public init(id: Int,
                type: EQBandType,
                frequency: Double,
                gainDB: Double = 0,
                q: Double = 0.7,
                isEnabled: Bool = false) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }

    /// The range the controls offer for *this* band.
    ///
    /// Widened when the band already carries a higher Q, so importing an AutoEq
    /// or Equalizer APO curve with a resonant shelf keeps its exact value
    /// instead of being silently pulled down the moment the control is touched.
    public var editableQRange: ClosedRange<Double> {
        let base = type.editableQRange
        return base.lowerBound...Swift.max(base.upperBound, q)
    }

    public var clamped: EQBand {
        var band = self
        band.frequency = min(max(frequency, Self.frequencyRange.lowerBound),
                             Self.frequencyRange.upperBound)
        band.gainDB = min(max(gainDB, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        band.q = min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound)
        return band
    }

    /// Mirrors EQ Eight: 1–2 cut/shelf, 3–6 bells, 7–8 shelf/cut.
    /// The four bells start enabled so a curve can be dragged immediately;
    /// the outer four are off until asked for.
    public static let defaultBands: [EQBand] = [
        EQBand(id: 0, type: .lowCut, frequency: 40, q: 0.7),
        EQBand(id: 1, type: .lowShelf, frequency: 120, q: 0.7),
        EQBand(id: 2, type: .bell, frequency: 250, q: 1.0, isEnabled: true),
        EQBand(id: 3, type: .bell, frequency: 800, q: 1.0, isEnabled: true),
        EQBand(id: 4, type: .bell, frequency: 2_500, q: 1.0, isEnabled: true),
        EQBand(id: 5, type: .bell, frequency: 6_000, q: 1.0, isEnabled: true),
        EQBand(id: 6, type: .highShelf, frequency: 10_000, q: 0.7),
        EQBand(id: 7, type: .highCut, frequency: 18_000, q: 0.7),
    ]

    public static let count = defaultBands.count
}

/// The whole EQ for one chain.
public struct EQSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var bands: [EQBand]
    /// EQ Eight's "Adapt. Q": Q widens as gain approaches zero, so small moves
    /// stay broad and large ones stay surgical.
    ///
    /// Off by default and deliberately so — an AutoEq or EQ Eight preset
    /// specifies exact Q values, and silently reinterpreting them would make
    /// imported curves wrong.
    public var adaptiveQ: Bool

    public init(isEnabled: Bool = true,
                bands: [EQBand] = EQBand.defaultBands,
                adaptiveQ: Bool = false) {
        self.isEnabled = isEnabled
        self.bands = bands
        self.adaptiveQ = adaptiveQ
    }
}
