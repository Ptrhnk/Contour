import ContourDSP
import SwiftUI

/// Curve plus numeric editing for the selected band.
///
/// Numeric entry is not a nicety: transcribing a curve from AutoEq or an
/// existing EQ Eight preset needs exact values, which dragging cannot give.
struct EQSection: View {
    @Binding var settings: ChainSettings
    var sampleRate: Double

    @State private var model = EQCurveModel()
    @State private var selectedBand = 2

    private static let trimRange =
        Double(ChainSettings.trimRange.lowerBound)...Double(ChainSettings.trimRange.upperBound)

    private var band: Binding<EQBand> {
        Binding(get: { settings.eq.bands[min(selectedBand, settings.eq.bands.count - 1)] },
                set: { settings.eq.bands[min(selectedBand, settings.eq.bands.count - 1)] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            EQCurveView(settings: $settings.eq,
                        selectedBand: $selectedBand,
                        model: model,
                        sampleRate: sampleRate)
                .opacity(settings.eq.isEnabled ? 1 : 0.4)

            bandEditor
            trimRow
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Toggle("EQ", isOn: $settings.eq.isEnabled)
                .toggleStyle(.checkbox)
                .font(.callout.weight(.medium))
            Spacer()
            Toggle("Adapt. Q", isOn: $settings.eq.adaptiveQ)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Q widens as gain approaches zero. Off by default so imported "
                      + "AutoEq and EQ Eight curves keep their exact Q values.")
        }
    }

    // MARK: - Band editor

    private var bandEditor: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(settings.eq.bands.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedBand = index
                    } label: {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 20, height: 18)
                            .background(index == selectedBand
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(item.isEnabled ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isEnabled ? item.type.title : "\(item.type.title) (off)")
                }
                Spacer()
                Toggle("On", isOn: band.isEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack(spacing: 6) {
                Picker("", selection: band.type) {
                    ForEach(EQBandType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 104)

                numberField("Freq", value: band.frequency,
                            range: EQBand.frequencyRange, suffix: "Hz", width: 62)
                numberField("Gain", value: band.gainDB,
                            range: EQBand.gainRange, suffix: "dB", width: 52)
                    .disabled(!band.wrappedValue.type.usesGain)
                numberField("Q", value: band.q,
                            range: EQBand.qRange, suffix: "", width: 44)
            }
        }
    }

    private func numberField(_ label: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             suffix: String,
                             width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(suffix.isEmpty ? label : "\(label) (\(suffix))")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("", value: Binding(get: { value.wrappedValue },
                                         set: { value.wrappedValue =
                                             min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption.monospacedDigit())
                .frame(width: width)
        }
    }

    // MARK: - Trim

    private var trimRow: some View {
        HStack(spacing: 8) {
            Text("Trim").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(settings.inputTrimDB) },
                                  set: { settings.inputTrimDB = Float($0) }),
                   in: Self.trimRange)
                .controlSize(.small)
            Text(String(format: "%.1f dB", settings.inputTrimDB))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
            // Boosts raise peak level; attenuating digitally before the DAC is
            // free, so make the level back up on the hardware knob (§5.5).
            Button("Auto") {
                let boost = model.maximumBoostDB
                settings.inputTrimDB = Float(min(max(-boost, Double(ChainSettings.trimRange.lowerBound)), 0))
            }
            .controlSize(.small)
            .help("Set trim to −(maximum boost) so the EQ cannot clip")
        }
    }
}
