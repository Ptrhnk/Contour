import ContourDSP
import Foundation

/// Which output pair the audio is going to. Chain A is the speaker pair
/// (out 1/2), chain B the headphone pair (out 3/4).
enum Destination: String, CaseIterable, Identifiable, Sendable {
    case speakers
    case headphones
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speakers: "Speakers"
        case .headphones: "Headphones"
        case .both: "Both"
        }
    }

    var symbol: String {
        switch self {
        case .speakers: "hifispeaker"
        case .headphones: "headphones"
        case .both: "waveform"
        }
    }

    var includesA: Bool { self != .headphones }
    var includesB: Bool { self != .speakers }
}

enum Chain: Int, CaseIterable, Identifiable, Sendable {
    case a = 0
    case b = 1

    var id: Int { rawValue }
    var title: String { self == .a ? "Speakers" : "Headphones" }
    var outputPairLabel: String { self == .a ? "out 1/2" : "out 3/4" }
}

/// Realtime-side parameters for one chain. Plain values only — this crosses to
/// the audio thread through `TripleBuffer`, so it must stay `BitwiseCopyable`.
struct ChainParameters: Equatable, BitwiseCopyable {
    var isActive: Bool = true
    /// Linear, not dB. Applied before the processing list; the EQ's
    /// "compensate for max boost" action will drive this in step 3.
    var inputTrim: Float = 1
    /// Linear. This is the control that removes the hardware knob-turning:
    /// set once per destination so switching needs no level change.
    var outputGain: Float = 1
}

struct EngineParameters: Equatable, BitwiseCopyable {
    var a = ChainParameters()
    var b = ChainParameters()

    subscript(chain: Chain) -> ChainParameters {
        get { chain == .a ? a : b }
        set { if chain == .a { a = newValue } else { b = newValue } }
    }
}

/// UI-side settings for one chain, persisted. Gains live here in dB because
/// that is what the user edits; the linear conversion happens on publish.
struct ChainSettings: Codable, Equatable, Sendable {
    var outputGainDB: Float = 0
    var inputTrimDB: Float = 0
    var eq = EQSettings()

    static let gainRange: ClosedRange<Float> = -60...12
    static let trimRange: ClosedRange<Float> = -24...0

    /// Decoding tolerates settings saved before the EQ existed.
    enum CodingKeys: String, CodingKey {
        case outputGainDB, inputTrimDB, eq
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputGainDB = try container.decodeIfPresent(Float.self, forKey: .outputGainDB) ?? 0
        inputTrimDB = try container.decodeIfPresent(Float.self, forKey: .inputTrimDB) ?? 0
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq) ?? EQSettings()
    }
}

enum Decibels {
    static let silenceFloor: Float = -60

    static func toLinear(_ db: Float) -> Float {
        db <= silenceFloor ? 0 : pow(10, db / 20)
    }

    static func fromLinear(_ linear: Float) -> Float {
        linear <= 0 ? -Float.infinity : 20 * log10(linear)
    }
}
