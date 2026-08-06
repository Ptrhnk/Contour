import AppKit
import ContourDSP
import SwiftUI

/// The large, resizable EQ editor.
///
/// A real `Window` scene rather than a resized popover: the menu-bar panel has
/// no placement API and fights any attempt to move it, while a `Window` can be
/// centred, sized and left open beside whatever you are listening to.
struct EQWindowView: View {
    @Bindable var engine: AudioEngine

    @State private var chain: Chain = .a
    @State private var model = EQCurveModel()
    @State private var selectedBand = 2
    @State private var transferMessage: String?

    static let id = "eq-editor"
    static let windowTitle = "Contour EQ"

    /// Equal widths, so the middle knob sits on the group's centre line.
    private static let knobColumnWidth: CGFloat = 74

    private static let trimRange =
        Double(ChainSettings.trimRange.lowerBound)...Double(ChainSettings.trimRange.upperBound)
    private static let gainRange =
        Double(ChainSettings.gainRange.lowerBound)...Double(ChainSettings.gainRange.upperBound)

    private var visibleChains: [Chain] {
        guard engine.supportsTwoChains else { return [.a] }
        switch engine.destination {
        case .speakers: return [.a]
        case .headphones: return [.b]
        case .both: return Chain.allCases
        }
    }

    private var shownChain: Chain {
        visibleChains.contains(chain) ? chain : (visibleChains.first ?? .a)
    }

    private var settings: Binding<ChainSettings> {
        shownChain == .a ? $engine.chainA : $engine.chainB
    }

    /// The trim in force: derived when auto-trim is on, manual otherwise.
    private var shownTrimDB: Float {
        engine.effectiveTrimDB(for: shownChain)
    }

    private var band: Binding<EQBand> {
        Binding(get: { settings.wrappedValue.eq.bands[safe: selectedBand] },
                set: { settings.wrappedValue.eq.bands[safe: selectedBand] = $0 })
    }

    /// Master bypass greys the whole signal path, matching what switching the EQ
    /// off already does — the difference being that bypass leaves it *editable*.
    /// You are usually drawing the change you want to hear on the way back, and
    /// a control that cannot be touched during the comparison gets in the way.
    private var pathOpacity: Double { engine.isBypassed ? 0.4 : 1 }

    /// One value rather than two stacked modifiers: SwiftUI multiplies nested
    /// opacities, so an EQ that is both off and bypassed would fade to 0.16 and
    /// read as broken rather than idle.
    private var eqOpacity: Double {
        settings.wrappedValue.eq.isEnabled && !engine.isBypassed ? 1 : 0.4
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar

            if let transferMessage {
                Text(transferMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            EQCurveView(settings: settings.eq,
                        selectedBand: $selectedBand,
                        model: model,
                        sampleRate: engine.eqSampleRate,
                        handleRadius: 13)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(!settings.wrappedValue.eq.isEnabled)
                .opacity(eqOpacity)

            bandStrip
                .disabled(!settings.wrappedValue.eq.isEnabled)
                .opacity(eqOpacity)
            Divider()

            // Below the EQ: the list is the signal path, and reading it under
            // the thing being edited matches the order audio actually travels.
            ProcessingListView(engine: engine, chain: shownChain)
                .opacity(pathOpacity)

            Divider()
            levels
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(WindowConfigurator().frame(width: 0, height: 0))
        .onAppear { engine.beginObservingMeters() }
        .onDisappear { engine.endObservingMeters() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            if visibleChains.count > 1 {
                Picker("", selection: $chain) {
                    ForEach(visibleChains) { chain in
                        Text(chain.title).tag(chain)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Label(engine.title(for: shownChain),
                      systemImage: engine.symbol(for: shownChain))
                    .font(.headline)
            }

            if engine.supportsTwoChains {
                Text(shownChain.outputPairLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 16)

            PresetBar(engine: engine, chain: shownChain)

            Divider().frame(height: 16)

            PowerToggle(isOn: settings.eq.isEnabled, diameter: 20)
                .help(settings.wrappedValue.eq.isEnabled ? "EQ on" : "EQ off")
            Text("EQ").font(.callout.weight(.medium))
            AutoEqTransferButton(settings: settings) { transferMessage = $0 }
                .disabled(!settings.wrappedValue.eq.isEnabled)
                .opacity(settings.wrappedValue.eq.isEnabled ? 1 : 0.4)
            Button("Flatten") {
                for index in settings.wrappedValue.eq.bands.indices {
                    settings.wrappedValue.eq.bands[index].gainDB = 0
                }
            }
            .disabled(!settings.wrappedValue.eq.isEnabled
                      || settings.wrappedValue.eq.bands.allSatisfy { $0.gainDB == 0 })
            .opacity(settings.wrappedValue.eq.isEnabled ? 1 : 0.4)
            // Everything EQ-related greys with it — except the power toggle
            // itself, which has to stay live to switch it back on.
            Toggle("Match", isOn: settings.loudnessMatch)
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!settings.wrappedValue.eq.isEnabled)
                .opacity(settings.wrappedValue.eq.isEnabled ? 1 : 0.4)
                .help("Compensate the EQ's average level change, so switching it "
                      + "off does not also change loudness.")
            Toggle("Adapt. Q", isOn: settings.eq.adaptiveQ)
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!settings.wrappedValue.eq.isEnabled)
                .opacity(settings.wrappedValue.eq.isEnabled ? 1 : 0.4)

            Spacer()

            // Master bypass belongs here as well as in the popover: this is
            // where the curve is being drawn, so this is where "what does it
            // actually sound like without any of it" gets asked.
            Toggle("Bypass", isOn: $engine.isBypassed)
                .toggleStyle(.button)
                .controlSize(.small)
                .tint(.orange)
                .keyboardShortcut("b", modifiers: [])
                .disabled(!engine.status.isRunning)
                .help("Both chains fall back to the dry signal, crossfaded so the "
                      + "switch does not click. Trim and output gain still apply, "
                      + "so this compares the processing rather than the volume.")

            Divider().frame(height: 16)

            Button {
                engine.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!engine.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")

            Button {
                engine.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!engine.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")

        }
    }

    // MARK: - Band strip

    private var bandStrip: some View {
        VStack(spacing: 12) {
            // Numbered selectors spread across the full width, matching the
            // curve above them.
            HStack(spacing: 6) {
                ForEach(Array(settings.wrappedValue.eq.bands.enumerated()),
                        id: \.element.id) { index, item in
                    Button {
                        selectedBand = index
                    } label: {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(index == selectedBand
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(item.isEnabled ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.isEnabled ? item.type.title : "\(item.type.title) (off)")
                }
            }

            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Band \(selectedBand + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    FilterTypePicker(type: band.type,
                                     iconSize: CGSize(width: 26, height: 18))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: 22) {
                    knob("Freq", band.frequency, EQBand.frequencyRange, logarithmic: true,
                         defaultValue: nil, width: Self.knobColumnWidth)
                    knob("Gain", band.gainDB, EQBand.gainRange, logarithmic: false,
                         defaultValue: 0, width: Self.knobColumnWidth)
                        .disabled(!band.wrappedValue.type.usesGain)
                        .opacity(band.wrappedValue.type.usesGain ? 1 : 0.4)
                    knob("Q", band.q, band.wrappedValue.editableQRange, logarithmic: true,
                         defaultValue: 0.7, width: Self.knobColumnWidth)
                }

                PowerToggle(isOn: band.isEnabled, diameter: 34)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(band.wrappedValue.isEnabled ? "Band on" : "Band off")
            }
        }
    }

    private func knob(_ title: String,
                      _ value: Binding<Double>,
                      _ range: ClosedRange<Double>,
                      logarithmic: Bool,
                      defaultValue: Double?,
                      width: CGFloat) -> some View {
        VStack(spacing: 5) {
            Knob(title: title,
                 value: value,
                 range: range,
                 logarithmic: logarithmic,
                 defaultValue: defaultValue,
                 diameter: 52)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("", value: Binding(get: { value.wrappedValue },
                                         set: { value.wrappedValue =
                                             min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: width)
        }
        .frame(width: width)
    }

    // MARK: - Levels

    private var levels: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                InputMeterRow(engine: engine)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                ChainMeterRow(engine: engine,
                              chain: shownChain,
                              isActive: engine.isChainActive(shownChain))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Trim").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    // Shows the trim actually in force. Binding the slider to
                    // the manual value while auto-trim drives the audio meant
                    // the window disagreed with both the popover and the sound.
                    Slider(value: Binding(
                        get: { Double(shownTrimDB) },
                        set: { settings.wrappedValue.inputTrimDB = Float($0) }),
                           in: Self.trimRange)
                        .disabled(settings.wrappedValue.autoTrim)
                    Text(String(format: "%.1f dB", shownTrimDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(settings.wrappedValue.autoTrim
                                         ? Color.accentColor : .primary)
                        .frame(width: 56, alignment: .trailing)
                    Toggle("Auto", isOn: settings.autoTrim)
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
                HStack(spacing: 8) {
                    Text("Gain").font(.caption).foregroundStyle(.secondary).frame(width: 32,
                                                                                 alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(settings.wrappedValue.outputGainDB) },
                        set: { settings.wrappedValue.outputGainDB = Float($0) }),
                           in: Self.gainRange)
                    Text(Format.db(settings.wrappedValue.outputGainDB))
                        .font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
            }
            .frame(width: 320)
        }
    }
}

private extension Array where Element == EQBand {
    /// Selection can outlive a band list change; clamp rather than trap.
    subscript(safe index: Int) -> EQBand {
        get { self[Swift.min(Swift.max(index, 0), count - 1)] }
        set { self[Swift.min(Swift.max(index, 0), count - 1)] = newValue }
    }
}
