import SwiftUI

struct PopoverView: View {
    @Bindable var engine: AudioEngine
    var launchAgent: LaunchAgent
    @Environment(\.openWindow) private var openWindow
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

            // Only the chains the current destination actually feeds. Showing a
            // greyed-out EQ for a chain that is off is just noise.
            if visibleChains.count > 1 {
                Picker("", selection: $editingChain) {
                    ForEach(visibleChains) { chain in
                        Text(chain.title).tag(chain)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ChainSection(engine: engine, chain: shownChain)

            Divider()
            details
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 420)
        .onAppear {
            engine.beginObservingMeters()
            engine.refreshEnvironment()
            launchAgent.refresh()
        }
        .onDisappear { engine.endObservingMeters() }
    }

    /// Opens the editor, or raises it if it is already open and buried.
    ///
    /// This is the alternative to keeping the window permanently on top: the
    /// menu bar icon is how you find it again, so it does not have to sit above
    /// everything else the rest of the time.
    private func showEQWindow() {
        // The popover is key while it is open; dismiss it so the window is not
        // opening behind a panel that is about to vanish anyway.
        let popover = NSApp.keyWindow
        if popover?.title != EQWindowView.windowTitle {
            popover?.orderOut(nil)
        }

        openWindow(id: EQWindowView.id)

        // The scene may only exist after this runloop turn, and an LSUIElement
        // app does not come forward on its own.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: {
                $0.title == EQWindowView.windowTitle
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Chains the destination feeds. A stereo-only interface has one regardless.
    private var visibleChains: [Chain] {
        guard engine.supportsTwoChains else { return [.a] }
        switch engine.destination {
        case .speakers: return [.a]
        case .headphones: return [.b]
        case .both: return Chain.allCases
        }
    }

    private var shownChain: Chain {
        visibleChains.contains(editingChain) ? editingChain : (visibleChains.first ?? .a)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("Contour").font(.headline)
            Text(Bundle.main.shortVersion)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Contour \(Bundle.main.shortVersion) (build \(Bundle.main.buildNumber))")
            Spacer()
            Button {
                showEQWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help("Open the large EQ editor, or bring it to the front")
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
            if engine.interfaceHasSoftwareVolume {
                GridRow {
                    Text("Volume").gridLabel()
                    HStack(spacing: 6) {
                        Slider(value: Binding(
                            get: { Double(engine.interfaceVolume ?? 0) },
                            set: { engine.setInterfaceVolume(Float($0)) }), in: 0...1)
                            .controlSize(.small)
                        Text("\(Int(((engine.interfaceVolume ?? 0) * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help("This device has a software volume control. The keyboard "
                          + "keys act on the system output device (BlackHole), not "
                          + "on this one.")
                }
            }
            GridRow {
                Text("Sample rate").gridLabel()
                Text(engine.sampleRate > 0 ? "\(Int(engine.sampleRate)) Hz" : "—").gridValue()
            }
            GridRow {
                Text("Latency").gridLabel()
                Text(latencyText).gridValue()
            }
            GridRow {
                Text("At login").gridLabel()
                HStack(spacing: 6) {
                    Toggle("Launch at login, restart on crash", isOn: Binding(
                        get: { launchAgent.isEnabled },
                        set: { launchAgent.setEnabled($0) }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    if launchAgent.isEnabled {
                        Button("Login Items…") { launchAgent.openLoginItemsSettings() }
                            .controlSize(.small)
                            .help("Contour appears there as a background item")
                    }
                }
                .help("With BlackHole as the system output, nothing drains it while "
                      + "Contour is not running — so there is no sound at all. "
                      + "launchd also restarts Contour if it exits abnormally, which "
                      + "is what a crashing plugin looks like. Quitting from the menu "
                      + "stays quit.")
            }
            if let failure = launchAgent.failure {
                GridRow {
                    Text("").gridLabel()
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var interfaceSelection: Binding<String> {
        Binding(get: { engine.interface?.uid ?? "" },
                set: { selected in
                    // The Picker echoes the getter back on first layout; that is
                    // not a user choice and must not count as one.
                    guard selected != engine.interface?.uid else { return }
                    engine.interfaceUID = selected.isEmpty ? nil : selected
                })
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

    private var isActive: Bool { engine.isChainActive(chain) }

    private var settings: Binding<ChainSettings> {
        chain == .a ? $engine.chainA : $engine.chainB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: engine.symbol(for: chain))
                    .foregroundStyle(isActive ? .primary : .secondary)
                Text(engine.title(for: chain)).font(.callout.weight(.medium))
                if engine.supportsTwoChains {
                    Text(chain.outputPairLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !isActive { Text("off").font(.caption).foregroundStyle(.secondary) }
            }

            PresetBar(engine: engine, chain: chain)

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
            // The EQ comes first because it is what gets touched. The plugin
            // order rarely changes once set, so the list sits underneath rather
            // than pushing the curve down the panel.
            EQSection(settings: settings, sampleRate: engine.eqSampleRate)
            Divider()
            ProcessingListView(engine: engine, chain: chain)
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

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

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
