import Foundation

/// AutoEq / Equalizer APO `ParametricEQ.txt`.
///
/// ```
/// Preamp: -6.2 dB
/// Filter 1: ON PK Fc 105 Hz Gain 3.4 dB Q 0.70
/// Filter 2: ON LSC Fc 677 Hz Gain 2.0 dB Q 3.00
/// ```
///
/// This is the one shareable artefact: a curve in this format restores anywhere,
/// unlike a Contour preset, which carries opaque plugin state and only works on a
/// machine with the same plugins installed (§6a).
public enum AutoEqPreset {

    public struct Imported: Equatable, Sendable {
        public var preampDB: Double
        public var bands: [EQBand]
        /// Never fatal. An unknown filter type is skipped with a note rather
        /// than failing the whole import (§5.6).
        public var warnings: [String]
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case noFilters

        public var errorDescription: String? {
            switch self {
            case .noFilters: "No filters found. Expected AutoEq ParametricEQ.txt text."
            }
        }
    }

    /// Equalizer APO's tokens. `LS`/`HS` appear in older exports alongside the
    /// `LSC`/`HSC` that AutoEq settled on.
    private static let types: [String: EQBandType] = [
        "PK": .bell, "PEQ": .bell, "MODAL": .bell,
        "LSC": .lowShelf, "LS": .lowShelf, "LSQ": .lowShelf,
        "HSC": .highShelf, "HS": .highShelf, "HSQ": .highShelf,
        "LP": .highCut, "LPQ": .highCut,
        "HP": .lowCut, "HPQ": .lowCut,
        "NO": .notch,
    ]

    public static func parse(_ text: String, bandCount: Int = EQBand.count) throws -> Imported {
        var preamp = 0.0
        var parsed: [EQBand] = []
        var warnings: [String] = []
        var skippedForCapacity = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.lowercased().hasPrefix("preamp") {
                if let value = number(after: "preamp:", in: line) ?? firstNumber(in: line) {
                    preamp = value
                }
                continue
            }
            guard line.lowercased().hasPrefix("filter") else { continue }

            let fields = line.split(separator: " ").map(String.init)
            // "Filter 1: ON PK ..." — anything not ON is a disabled slot.
            let isEnabled = fields.contains { $0.uppercased() == "ON" }
            guard let typeToken = fields.first(where: { types[$0.uppercased()] != nil }) else {
                if isEnabled, let unknown = fields.dropFirst(3).first {
                    warnings.append("Skipped unsupported filter type “\(unknown)”.")
                }
                continue
            }
            guard isEnabled else { continue }
            guard let frequency = number(after: "fc", in: line) else {
                warnings.append("Skipped a filter with no frequency.")
                continue
            }

            guard parsed.count < bandCount else {
                skippedForCapacity += 1
                continue
            }

            let type = types[typeToken.uppercased()]!
            parsed.append(EQBand(id: parsed.count,
                                 type: type,
                                 frequency: frequency,
                                 gainDB: type.usesGain ? (number(after: "gain", in: line) ?? 0) : 0,
                                 q: number(after: "q", in: line) ?? 0.7,
                                 isEnabled: true).clamped)
        }

        guard !parsed.isEmpty else { throw ImportError.noFilters }
        if skippedForCapacity > 0 {
            warnings.append("""
                This curve has \(parsed.count + skippedForCapacity) filters; \
                Contour has \(bandCount) bands, so the last \(skippedForCapacity) \
                were dropped.
                """)
        }
        return Imported(preampDB: preamp, bands: parsed, warnings: warnings)
    }

    /// Fills the remaining slots with disabled bands so a chain always has a
    /// full set, keeping the imported ones first.
    public static func bands(from imported: Imported,
                             bandCount: Int = EQBand.count) -> [EQBand] {
        var result = imported.bands
        for index in result.indices { result[index].id = index }
        let defaults = EQBand.defaultBands
        while result.count < bandCount {
            var filler = defaults[min(result.count, defaults.count - 1)]
            filler.id = result.count
            filler.isEnabled = false
            filler.gainDB = 0
            result.append(filler)
        }
        return Array(result.prefix(bandCount))
    }

    public static func export(bands: [EQBand], preampDB: Double) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preampDB)]
        for (index, band) in bands.enumerated() {
            let token = types.first { $0.value == band.type && $0.key.count <= 3 }?.key
                ?? defaultToken(band.type)
            let state = band.isEnabled ? "ON" : "OFF"
            lines.append(String(format: "Filter %d: %@ %@ Fc %g Hz Gain %.1f dB Q %.2f",
                                index + 1, state, token, band.frequency, band.gainDB, band.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func defaultToken(_ type: EQBandType) -> String {
        switch type {
        case .bell: "PK"
        case .lowShelf: "LSC"
        case .highShelf: "HSC"
        case .lowCut: "HP"
        case .highCut: "LP"
        case .notch: "NO"
        }
    }

    // MARK: - Numbers

    /// Finds the number following a keyword, so field order does not matter.
    private static func number(after keyword: String, in line: String) -> Double? {
        let tokens = line.split(separator: " ").map(String.init)
        let target = keyword.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        for (index, token) in tokens.enumerated() {
            let cleaned = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard cleaned == target else { continue }
            for candidate in tokens.dropFirst(index + 1) {
                if let value = decimal(candidate) { return value }
            }
        }
        return nil
    }

    private static func firstNumber(in line: String) -> Double? {
        line.split(separator: " ").compactMap { decimal(String($0)) }.first
    }

    /// Tolerates a comma decimal separator, which some exports carry.
    private static func decimal(_ token: String) -> Double? {
        let cleaned = token
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil
        else { return nil }
        return Double(cleaned)
    }
}
