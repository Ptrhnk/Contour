import Foundation
import Testing
@testable import ContourDSP

@Suite("AutoEq text presets")
struct AutoEqPresetTests {

    /// Verbatim from an AutoEq ParametricEQ.txt.
    let sample = """
        Preamp: -6.2 dB
        Filter 1: ON PK Fc 105 Hz Gain 3.4 dB Q 0.70
        Filter 2: ON LSC Fc 677 Hz Gain 2.0 dB Q 3.00
        Filter 3: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.70
        Filter 4: ON PK Fc 2500 Hz Gain -4.8 dB Q 2.10
        """

    @Test("Parses preamp, types, frequencies, gains and Q")
    func parsesSample() throws {
        let imported = try AutoEqPreset.parse(sample)
        #expect(imported.preampDB == -6.2)
        #expect(imported.bands.count == 4)
        #expect(imported.warnings.isEmpty)

        #expect(imported.bands[0].type == .bell)
        #expect(imported.bands[0].frequency == 105)
        #expect(imported.bands[0].gainDB == 3.4)
        #expect(imported.bands[0].q == 0.70)

        #expect(imported.bands[1].type == .lowShelf)
        #expect(imported.bands[1].frequency == 677)
        #expect(imported.bands[2].type == .highShelf)
        #expect(imported.bands[2].gainDB == -1.5)
        #expect(imported.bands[3].q == 2.10)
    }

    @Test("Disabled filters are skipped")
    func skipsDisabled() throws {
        let imported = try AutoEqPreset.parse("""
            Preamp: 0 dB
            Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1
            Filter 2: OFF PK Fc 200 Hz Gain 5 dB Q 1
            Filter 3: None
            """)
        #expect(imported.bands.count == 1)
        #expect(imported.bands[0].frequency == 100)
    }

    /// An unknown type must not fail the whole import (§5.6).
    @Test("Unknown filter types warn rather than throw")
    func unknownTypeWarns() throws {
        let imported = try AutoEqPreset.parse("""
            Preamp: 0 dB
            Filter 1: ON PK Fc 100 Hz Gain 1 dB Q 1
            Filter 2: ON XYZ Fc 200 Hz Gain 5 dB Q 1
            """)
        #expect(imported.bands.count == 1)
        #expect(!imported.warnings.isEmpty)
    }

    @Test("Cuts import without a gain field")
    func cutsWithoutGain() throws {
        let imported = try AutoEqPreset.parse("""
            Preamp: 0 dB
            Filter 1: ON HP Fc 30 Hz Q 0.70
            Filter 2: ON LP Fc 18000 Hz Q 0.70
            """)
        #expect(imported.bands.count == 2)
        #expect(imported.bands[0].type == .lowCut)
        #expect(imported.bands[0].frequency == 30)
        #expect(imported.bands[1].type == .highCut)
    }

    @Test("More filters than bands warns and keeps the first ones")
    func tooManyFilters() throws {
        let lines = (1...12).map {
            "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 1 dB Q 1"
        }.joined(separator: "\n")
        let imported = try AutoEqPreset.parse("Preamp: 0 dB\n" + lines)
        #expect(imported.bands.count == EQBand.count)
        #expect(imported.warnings.contains { $0.contains("12 filters") })
    }

    @Test("Text with no filters throws")
    func noFilters() {
        #expect(throws: AutoEqPreset.ImportError.noFilters) {
            try AutoEqPreset.parse("this is not a preset")
        }
    }

    @Test("Remaining slots are filled with disabled bands")
    func fillsRemainingBands() throws {
        let imported = try AutoEqPreset.parse(sample)
        let bands = AutoEqPreset.bands(from: imported)
        #expect(bands.count == EQBand.count)
        #expect(bands.prefix(4).allSatisfy { $0.isEnabled })
        #expect(bands.dropFirst(4).allSatisfy { !$0.isEnabled })
        #expect(bands.map(\.id) == Array(0..<EQBand.count))
    }

    @Test("Export round-trips through the parser")
    func roundTrip() throws {
        let original = try AutoEqPreset.parse(sample)
        let text = AutoEqPreset.export(bands: AutoEqPreset.bands(from: original),
                                       preampDB: original.preampDB)
        let reparsed = try AutoEqPreset.parse(text)
        #expect(reparsed.preampDB == original.preampDB)
        #expect(reparsed.bands.count == original.bands.count)
        for (a, b) in zip(reparsed.bands, original.bands) {
            #expect(a.type == b.type)
            #expect(abs(a.frequency - b.frequency) < 0.5)
            #expect(abs(a.gainDB - b.gainDB) < 0.05)
            #expect(abs(a.q - b.q) < 0.005)
        }
    }

    @Test("A comma decimal separator is tolerated")
    func commaDecimals() throws {
        let imported = try AutoEqPreset.parse("""
            Preamp: -3,5 dB
            Filter 1: ON PK Fc 1000 Hz Gain 2,5 dB Q 1,41
            """)
        #expect(imported.preampDB == -3.5)
        #expect(imported.bands[0].gainDB == 2.5)
        #expect(abs(imported.bands[0].q - 1.41) < 0.001)
    }
}
