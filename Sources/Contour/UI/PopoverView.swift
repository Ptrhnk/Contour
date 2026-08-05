import SwiftUI

struct PopoverView: View {
    @Bindable var engine: AudioEngine
    @State private var editingChain: Chain = .a

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            problems

            if engine.supportsTwoChains {
                Picker("", selection: $engine.destination) {
                    ForEach(Destination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            InputMeterRow(engine: engine)
            Divider()

            if engine.supportsTwoChains {
                Picker("", selection: $editingChain) {
                    ForEach(Chain.allCases) { chain in
                        Text(chain.title).tag(chain)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ChainSection(engine: engine, chain: engine.supportsTwoChains ? editingChain : .a)

            Divider()
            details
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 420)
        .onAppear {
            engine.isPopoverVisible = true
            engine.refreshEnvironment()
        }
        .onDisappear { engine.isPopoverVisible = false }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("Contour").font(.headline)
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .running: .green
        case .waiting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var statusText: String {
        switch engine.status {
        case .running: "Running"
        case .waiting: "Waiting"
        case .failed: "Error"
        case .stopped: "Stopped"
        }
    }

    // MARK: - Problems

    @ViewBuilder
    private var problems: some View {
        switch engine.status {
        case .waiting(let message), .failed(let message):
            Notice(text: message, tint: .orange) {
                if engine.microphoneAccess != .authorized {
                    Button(engine.microphoneAccess == .notDetermined
                           ? "Grant microphone access"
                           : "Open Privacy & Security") {
                        engine.requestMicrophoneAccess()
                    }
                }
            }
        case .running, .stopped:
            EmptyView()
        }

        if let capture = engine.capture, !engine.systemOutputIsCapture {
            Notice(text: "System output is “\(engine.systemOutput?.name ?? "unknown")”. "
                       + "Contour only hears audio sent to \(capture.name).",
                   tint: .orange) {
                Button("Set output to \(capture.name)") { engine.makeCaptureSystemOutput() }
            }
        }

        if let volume = engine.captureVolume, volume < 0.999 {
            Notice(text: "\(engine.capture?.name ?? "Capture device") volume is "
                       + "\(Int((volume * 100).rounded()))%. That attenuates digitally before "
                       + "Contour sees the audio — set it to 100% and use the hardware knob.",
                   tint: .yellow) {
                Button("Set to 100%") { engine.resetCaptureVolume() }
            }
        }
    }

    // MARK: - Details

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Interface").gridLabel()
                Picker("", selection: interfaceSelection) {
                    ForEach(engine.availableInterfaces) { device in
                        Text("\(device.name) (\(device.outputChannels) out)").tag(device.uid)
                    }
                    if engine.availableInterfaces.isEmpty {
                        Text("None found").tag("")
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            GridRow {
                Text("Sample rate").gridLabel()
                Text(engine.sampleRate > 0 ? "\(Int(engine.sampleRate)) Hz" : "—").gridValue()
            }
            GridRow {
                Text("Latency").gridLabel()
                Text(latencyText).gridValue()
            }
        }
    }

    private var interfaceSelection: Binding<String> {
        Binding(get: { engine.interface?.uid ?? "" },
                set: { engine.interfaceUID = $0.isEmpty ? nil : $0 })
    }

    private var latencyText: String {
        guard engine.sampleRate > 0, engine.latencyFrames > 0 else { return "—" }
        let ms = Double(engine.latencyFrames) / engine.sampleRate * 1000
        return String(format: "%.1f ms (%d frames)", ms, engine.latencyFrames)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if engine.status.isRunning {
                Button("Stop") { engine.stop() }
            } else {
                Button("Start") { engine.start() }
            }
            Button("Rescan") { engine.refreshEnvironment() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

// MARK: - Chain

private struct ChainSection: View {
    @Bindable var engine: AudioEngine
    let chain: Chain

    private static let gainRange =
        Double(ChainSettings.gainRange.lowerBound)...Double(ChainSettings.gainRange.upperBound)

    private var isActive: Bool {
        chain == .a ? engine.destination.includesA : engine.destination.includesB
    }

    private var settings: Binding<ChainSettings> {
        chain == .a ? $engine.chainA : $engine.chainB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: chain == .a ? "hifispeaker" : "headphones")
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(chain.title).font(.callout.weight(.medium))
                Text(chain.outputPairLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !isActive { Text("off").font(.caption).foregroundStyle(.secondary) }
            }

            ChainMeterRow(engine: engine, chain: chain, isActive: isActive)

            HStack(spacing: 8) {
                Text("Gain").font(.caption).foregroundStyle(.secondary)
                Slider(value: gain, in: Self.gainRange).controlSize(.small)
                // Click the readout to return to unity — the fastest way back to
                // a known level after chasing a match by ear.
                Button(Format.db(engine.settings(for: chain).outputGainDB)) {
                    var updated = engine.settings(for: chain)
                    updated.outputGainDB = 0
                    engine.setSettings(updated, for: chain)
                }
                .buttonStyle(.plain)
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
                .help("Click to reset to 0 dB")
            }

            Divider()
            EQSection(settings: settings, sampleRate: engine.eqSampleRate)
        }
        .opacity(isActive ? 1 : 0.6)
    }

    private var gain: Binding<Double> {
        Binding(get: { Double(engine.settings(for: chain).outputGainDB) },
                set: {
                    var updated = engine.settings(for: chain)
                    updated.outputGainDB = Float($0)
                    engine.setSettings(updated, for: chain)
                })
    }
}

// MARK: - Bits

enum Format {
    static func db(_ value: Float) -> String {
        guard value.isFinite, value > Decibels.silenceFloor else { return "−∞" }
        return String(format: "%+.1f dB", value)
    }
}

private struct Notice<Action: View>: View {
    let text: String
    let tint: Color
    @ViewBuilder var action: () -> Action

    init(text: String, tint: Color, @ViewBuilder action: @escaping () -> Action) {
        self.text = text
        self.tint = tint
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            action().controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.35)))
    }
}

extension Notice where Action == EmptyView {
    init(text: String, tint: Color) {
        self.init(text: text, tint: tint) { EmptyView() }
    }
}

private extension View {
    func gridLabel() -> some View {
        font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    func gridValue() -> some View {
        font(.caption.monospacedDigit())
    }
}
