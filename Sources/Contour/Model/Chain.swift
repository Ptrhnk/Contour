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
    /// Applied after the EQ, and only while it is enabled, so bypassing the EQ
    /// does not change loudness.
    var eqMakeup: Float = 1
    /// Linear, not dB. Applied before the processing list; the EQ's
    /// "compensate for max boost" action will drive this in step 3.
    var inputTrim: Float = 1
    /// Linear. This is the control that removes the hardware knob-turning:
    /// set once per destination so switching needs no level change.
    var outputGain: Float = 1
    /// Master bypass, as a crossfade amount: 1 processed, 0 dry. Input trim and
    /// output gain still apply either way, so the comparison is between the
    /// processing and nothing, not between two different volumes.
    var processedMix: Float = 1
}

struct EngineParameters: Equatable, BitwiseCopyable {
    var a = ChainParameters()
    var b = ChainParameters()

    subscript(chain: Chain) -> ChainParameters {
        get { chain == .a ? a : b }
        set { if chain == .a { a = newValue } else { b = newValue } }
    }
}

/// One entry in a chain's processing list.
///
/// The list replaces a pre/post-EQ distinction with something simpler: drag the
/// EQ above or below a plugin (§4).
struct ProcessingItem: Codable, Equatable, Sendable, Identifiable {
    enum Kind: Codable, Equatable, Sendable {
        case eq
        case plugin(AudioUnitDescriptor)
    }

    var id: UUID
    var kind: Kind
    var isBypassed: Bool
    /// `fullStateForDocument`, opaque binary. Only restores where the same
    /// plugin is installed, which is why presets are personal configuration
    /// rather than something to share (§6a).
    var state: Data?

    init(id: UUID = UUID(), kind: Kind, isBypassed: Bool = false, state: Data? = nil) {
        self.id = id
        self.kind = kind
        self.isBypassed = isBypassed
        self.state = state
    }

    var isEQ: Bool { if case .eq = kind { return true } else { return false } }

    var descriptor: AudioUnitDescriptor? {
        if case .plugin(let descriptor) = kind { return descriptor }
        return nil
    }

    var title: String {
        switch kind {
        case .eq: "EQ"
        case .plugin(let descriptor): descriptor.name
        }
    }
}

/// UI-side settings for one chain, persisted. Gains live here in dB because
/// that is what the user edits; the linear conversion happens on publish.
struct ChainSettings: Codable, Equatable, Sendable {
    var outputGainDB: Float = 0
    var inputTrimDB: Float = 0
    /// When on, trim tracks −(peak EQ boost) continuously, so raising a band
    /// pulls the trim down and lowering it lets the trim back up. The manual
    /// `inputTrimDB` is kept untouched so turning auto off restores it.
    var autoTrim: Bool = false
    /// Compensates the EQ's average level change so switching it off does not
    /// also change loudness. Peak-based trim cannot do this: a curve of cuts has
    /// no peak boost and still gets quieter.
    var loudnessMatch: Bool = false
    var eq = EQSettings()
    /// Ordered: everything before the EQ entry runs first, everything after it
    /// runs last. Always contains exactly one `.eq`.
    var processing: [ProcessingItem] = [ProcessingItem(kind: .eq)]

    static let gainRange: ClosedRange<Float> = -60...12
    static let trimRange: ClosedRange<Float> = -24...0

    /// Decoding tolerates settings saved before the EQ existed.
    enum CodingKeys: String, CodingKey {
        case outputGainDB, inputTrimDB, autoTrim, loudnessMatch, eq, processing
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputGainDB = try container.decodeIfPresent(Float.self, forKey: .outputGainDB) ?? 0
        inputTrimDB = try container.decodeIfPresent(Float.self, forKey: .inputTrimDB) ?? 0
        autoTrim = try container.decodeIfPresent(Bool.self, forKey: .autoTrim) ?? false
        loudnessMatch = try container.decodeIfPresent(Bool.self, forKey: .loudnessMatch) ?? false
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq) ?? EQSettings()
        processing = try container.decodeIfPresent([ProcessingItem].self, forKey: .processing)
            ?? [ProcessingItem(kind: .eq)]
        // Settings saved before the processing list existed, or edited by hand,
        // must still end up with exactly one EQ entry.
        if !processing.contains(where: \.isEQ) {
            processing.insert(ProcessingItem(kind: .eq), at: 0)
        }
    }

    /// Plugins that run before the EQ, then those after it.
    var pluginsBeforeEQ: [ProcessingItem] {
        guard let index = processing.firstIndex(where: \.isEQ) else { return [] }
        return Array(processing[..<index]).filter { !$0.isEQ }
    }

    var pluginsAfterEQ: [ProcessingItem] {
        guard let index = processing.firstIndex(where: \.isEQ) else { return processing }
        return Array(processing[processing.index(after: index)...]).filter { !$0.isEQ }
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
