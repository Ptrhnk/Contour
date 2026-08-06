import AppKit
import ContourDSP
import SwiftUI
import UniformTypeIdentifiers

/// Curve plus numeric editing for the selected band.
///
/// Numeric entry is not a nicety: transcribing a curve from AutoEq or an
/// existing EQ Eight preset needs exact values, which dragging cannot give.
struct EQSection: View {
    @Binding var settings: ChainSettings
    var sampleRate: Double

    @State private var model = EQCurveModel()
    @State private var selectedBand = 2

    @State private var transferMessage: String?

    private static let trimRange =
        Double(ChainSettings.trimRange.lowerBound)...Double(ChainSettings.trimRange.upperBound)

    private var band: Binding<EQBand> {
        Binding(get: { settings.eq.bands[min(selectedBand, settings.eq.bands.count - 1)] },
                set: { settings.eq.bands[min(selectedBand, settings.eq.bands.count - 1)] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // The curve has no intrinsic height any more, so the popover sets
            // one; the large window lets it fill instead.
            EQCurveView(settings: $settings.eq,
                        selectedBand: $selectedBand,
                        model: model,
                        sampleRate: sampleRate)
                .frame(height: 150)
                .opacity(settings.eq.isEnabled ? 1 : 0.4)
                .onDrop(of: [.fileURL, .plainText], isTargeted: nil, perform: handleDrop)

            bandEditor
            trimRow

            if let transferMessage {
                Text(transferMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Toggle("EQ", isOn: $settings.eq.isEnabled)
                .toggleStyle(.checkbox)
                .font(.callout.weight(.medium))
            Spacer()
            // Gains only. Frequencies, Qs, types and enabled flags survive, so a
            // curve you have shaped can be flattened and rebuilt without losing
            // where the bands sit.
            Button("Flatten") {
                for index in settings.eq.bands.indices {
                    settings.eq.bands[index].gainDB = 0
                }
            }
            .controlSize(.small)
            .disabled(settings.eq.bands.allSatisfy { $0.gainDB == 0 })
            .help("Set every band's gain to 0 dB. Frequencies and Q are kept.")
            Menu {
                Button("Paste AutoEq Text") { importFromClipboard() }
                Button("Open AutoEq File…") { importFromFile() }
                Divider()
                Button("Copy as AutoEq Text") { exportToClipboard() }
                Button("Save AutoEq File…") { exportToFile() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
            .help("Import or export the curve as AutoEq ParametricEQ.txt. "
                  + "You can also drop a file or text onto the curve.")

            Toggle("Adapt. Q", isOn: $settings.eq.adaptiveQ)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Q widens as gain approaches zero. Off by default so imported "
                      + "AutoEq and EQ Eight curves keep their exact Q values.")
        }
    }

    // MARK: - Band editor

    private var bandEditor: some View {
        VStack(spacing: 10) {
            // Spread across the full width so the selectors line up with the
            // curve above them.
            HStack(spacing: 4) {
                ForEach(Array(settings.eq.bands.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedBand = index
                    } label: {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                            .background(index == selectedBand
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(item.isEnabled ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isEnabled ? item.type.title : "\(item.type.title) (off)")
                }
            }

            // Equal-width side columns so the knobs land optically centred
            // rather than merely "after" the type picker.
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Band \(selectedBand + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Picker("", selection: band.type) {
                        ForEach(EQBandType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                .frame(width: 96, alignment: .leading)

                Spacer(minLength: 0)

                // Knobs and the On toggle form one group, centred in the space
                // left of the type column. Giving On its own fixed column made
                // its unused width show up as a gutter on the right edge.
                HStack(alignment: .top, spacing: 12) {
                    knobColumn(title: "Freq",
                               value: band.frequency,
                               range: EQBand.frequencyRange,
                               logarithmic: true,
                               defaultValue: nil,
                               fieldWidth: 60)

                    knobColumn(title: "Gain",
                               value: band.gainDB,
                               range: EQBand.gainRange,
                               logarithmic: false,
                               defaultValue: 0,
                               fieldWidth: 52)
                        .disabled(!band.wrappedValue.type.usesGain)
                        .opacity(band.wrappedValue.type.usesGain ? 1 : 0.4)

                    knobColumn(title: "Q",
                               value: band.q,
                               range: band.wrappedValue.editableQRange,
                               logarithmic: true,
                               defaultValue: 0.7,
                               fieldWidth: 48)

                    Toggle("On", isOn: band.isEnabled)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .padding(.top, 12)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// Knob over its numeric field. Both edit the same value: the knob for
    /// feel, the field for transcribing an exact curve.
    private func knobColumn(title: String,
                            value: Binding<Double>,
                            range: ClosedRange<Double>,
                            logarithmic: Bool,
                            defaultValue: Double?,
                            fieldWidth: CGFloat) -> some View {
        VStack(spacing: 3) {
            Knob(title: title,
                 value: value,
                 range: range,
                 logarithmic: logarithmic,
                 defaultValue: defaultValue)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            numberFieldOnly(value: value, range: range, width: fieldWidth)
        }
        // Fixed width: without it the columns size to their contents and the
        // narrowest one loses its label to compression, taking its vertical
        // alignment with it.
        .frame(width: fieldWidth)
    }

    private func numberFieldOnly(value: Binding<Double>,
                                 range: ClosedRange<Double>,
                                 width: CGFloat) -> some View {
        TextField("", value: Binding(get: { value.wrappedValue },
                                     set: { value.wrappedValue =
                                         min(max($0, range.lowerBound), range.upperBound) }),
                  format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }

    // MARK: - AutoEq text

    /// The curve alone, in the one format that transfers between machines.
    /// A Contour preset carries opaque plugin state and does not (§6a).
    private func apply(_ text: String) {
        do {
            let imported = try AutoEqPreset.parse(text)
            settings.eq.bands = AutoEqPreset.bands(from: imported)
            settings.eq.isEnabled = true
            // The file states its own preamp, so auto-trim would fight it.
            settings.autoTrim = false
            settings.inputTrimDB = Float(min(max(imported.preampDB,
                                                 Double(ChainSettings.trimRange.lowerBound)), 0))
            transferMessage = imported.warnings.isEmpty
                ? "Imported \(imported.bands.count) filters, preamp "
                    + String(format: "%.1f dB.", imported.preampDB)
                : imported.warnings.joined(separator: " ")
        } catch {
            transferMessage = error.localizedDescription
        }
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            transferMessage = "The clipboard has no text."
            return
        }
        apply(text)
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        apply(text)
    }

    private var exportText: String {
        AutoEqPreset.export(bands: settings.eq.bands, preampDB: Double(settings.inputTrimDB))
    }

    private func exportToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText, forType: .string)
        transferMessage = "Copied the curve as AutoEq text."
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ParametricEQ.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportText.write(to: url, atomically: true, encoding: .utf8)
            transferMessage = "Saved."
        } catch {
            transferMessage = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                Task { @MainActor in apply(text) }
            }
            return true
        }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let text = text as? String else { return }
            Task { @MainActor in apply(text) }
        }
        return true
    }

    // MARK: - Trim

    /// Shown value: the derived one when auto is on, the manual one otherwise.
    private var shownTrimDB: Float {
        settings.autoTrim && settings.eq.isEnabled ? autoTrimDB : settings.inputTrimDB
    }

    private var autoTrimDB: Float {
        let boost = EQCurveCache.maximumBoostDB(bands: settings.eq.bands,
                                                adaptiveQ: settings.eq.adaptiveQ,
                                                sampleRate: sampleRate)
        return Float(max(min(-boost, 0), Double(ChainSettings.trimRange.lowerBound)))
    }

    private var trimRow: some View {
        HStack(spacing: 8) {
            Text("Trim").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(shownTrimDB) },
                                  set: { settings.inputTrimDB = Float($0) }),
                   in: Self.trimRange)
                .controlSize(.small)
                .disabled(settings.autoTrim)
            Text(String(format: "%.1f dB", shownTrimDB))
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(settings.autoTrim ? Color.accentColor : .primary)
            // Sticky: trim follows −(peak boost) on every EQ move, up as well as
            // down. Boosts raise peak level, and attenuating digitally before
            // the DAC is free — make the level back up on the hardware knob.
            Toggle("Auto", isOn: $settings.autoTrim)
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Keep trim at \u{2212}(maximum EQ boost) automatically, "
                      + "so the EQ can never clip")
        }
    }
}
