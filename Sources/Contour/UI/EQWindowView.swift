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

    /// Floating by default: Contour has no Dock icon and no ⌘-Tab entry, so a
    /// window that falls behind another app is genuinely hard to retrieve.
    @AppStorage("eqWindowFloating") private var isFloating = true
    @State private var chain: Chain = .a
    @State private var model = EQCurveModel()
    @State private var selectedBand = 2

    static let id = "eq-editor"

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

    private var band: Binding<EQBand> {
        Binding(get: { settings.wrappedValue.eq.bands[safe: selectedBand] },
                set: { settings.wrappedValue.eq.bands[safe: selectedBand] = $0 })
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar

            EQCurveView(settings: settings.eq,
                        selectedBand: $selectedBand,
                        model: model,
                        sampleRate: engine.eqSampleRate,
                        handleRadius: 13)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(settings.wrappedValue.eq.isEnabled ? 1 : 0.4)

            bandStrip
            Divider()
            levels
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(WindowConfigurator(isFloating: isFloating).frame(width: 0, height: 0))
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

            Toggle("EQ", isOn: settings.eq.isEnabled).toggleStyle(.checkbox)
            Button("Flatten") {
                for index in settings.wrappedValue.eq.bands.indices {
                    settings.wrappedValue.eq.bands[index].gainDB = 0
                }
            }
            .disabled(settings.wrappedValue.eq.bands.allSatisfy { $0.gainDB == 0 })
            Toggle("Adapt. Q", isOn: settings.eq.adaptiveQ).toggleStyle(.checkbox)

            Spacer()

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

            Toggle(isOn: $isFloating) {
                Image(systemName: isFloating ? "pin.fill" : "pin.slash")
            }
            .toggleStyle(.button)
            .help("Keep this window above other apps. Contour has no Dock icon, "
                  + "so an unpinned window can be hard to find again.")
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

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Type").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("", selection: band.type) {
                        ForEach(EQBandType.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Spacer(minLength: 0)

                HStack(alignment: .top, spacing: 22) {
                    knob("Freq", band.frequency, EQBand.frequencyRange, logarithmic: true,
                         defaultValue: nil, width: 78)
                    knob("Gain", band.gainDB, EQBand.gainRange, logarithmic: false,
                         defaultValue: 0, width: 66)
                        .disabled(!band.wrappedValue.type.usesGain)
                        .opacity(band.wrappedValue.type.usesGain ? 1 : 0.4)
                    knob("Q", band.q, band.wrappedValue.editableQRange, logarithmic: true,
                         defaultValue: 0.7, width: 60)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("Band \(selectedBand + 1)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Toggle("On", isOn: band.isEnabled).toggleStyle(.checkbox)
                }
                .frame(width: 130, alignment: .trailing)
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
                    Text("Trim").font(.caption).foregroundStyle(.secondary).frame(width: 32,
                                                                                 alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(settings.wrappedValue.inputTrimDB) },
                        set: { settings.wrappedValue.inputTrimDB = Float($0) }),
                           in: Self.trimRange)
                        .disabled(settings.wrappedValue.autoTrim)
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
