import Foundation
import Testing
@testable import ContourDSP

@Suite("Ten bands, and settings saved with eight")
struct EQBandCountTests {

    /// The shape AutoEq emits for Equalizer APO: low shelf, eight peaks, high shelf.
    let autoEqTen = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
        Filter 2: ON PK Fc 200 Hz Gain -2.1 dB Q 0.80
        Filter 3: ON PK Fc 1200 Hz Gain 1.9 dB Q 1.20
        Filter 4: ON PK Fc 2400 Hz Gain -3.0 dB Q 2.00
        Filter 5: ON PK Fc 3500 Hz Gain 2.5 dB Q 3.10
        Filter 6: ON PK Fc 5200 Hz Gain -2.7 dB Q 4.00
        Filter 7: ON PK Fc 6800 Hz Gain 3.3 dB Q 5.20
        Filter 8: ON PK Fc 8900 Hz Gain -1.8 dB Q 2.40
        Filter 9: ON PK Fc 13000 Hz Gain 1.2 dB Q 1.50
        Filter 10: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.70
        """

    @Test("An AutoEq Equalizer APO curve imports whole")
    func autoEqFits() throws {
        let imported = try AutoEqPreset.parse(autoEqTen)
        #expect(EQBand.count == 10)
        #expect(imported.bands.count == 10)
        #expect(imported.warnings.isEmpty)
        #expect(imported.bands.last?.type == .highShelf)
    }

    @Test("Eight saved bands gain two disabled bells ahead of the high shelf")
    func migratesEightBands() throws {
        var legacy = Array(EQBand.defaultBands.prefix(6)) + Array(EQBand.defaultBands.suffix(2))
        legacy = legacy.enumerated().map { index, band in
            var band = band
            band.id = index
            return band
        }
        legacy[2].gainDB = 4
        let json = try JSONEncoder().encode(
            EQSettings(isEnabled: true, bands: legacy, adaptiveQ: false))

        let decoded = try JSONDecoder().decode(EQSettings.self, from: json)

        #expect(decoded.bands.count == EQBand.count)
        #expect(decoded.bands.map(\.id) == Array(0..<EQBand.count))
        #expect(decoded.bands[2].gainDB == 4)
        #expect(decoded.bands[6].type == .bell && !decoded.bands[6].isEnabled)
        #expect(decoded.bands[7].type == .bell && !decoded.bands[7].isEnabled)
        #expect(decoded.bands[8].type == .highShelf)
        #expect(decoded.bands[9].type == .highCut)
    }

    @Test("Ten saved bands round-trip unchanged")
    func tenRoundTrip() throws {
        var settings = EQSettings()
        settings.bands[7].isEnabled = true
        settings.bands[7].gainDB = -3
        let json = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(EQSettings.self, from: json) == settings)
    }

    @Test("Any other count is padded or truncated to ten")
    func otherCounts() {
        #expect(EQBand.normalized([]) == EQBand.defaultBands)
        let twelve = (0..<12).map { EQBand(id: $0, type: .bell, frequency: 1_000) }
        #expect(EQBand.normalized(twelve).count == EQBand.count)
    }
}
