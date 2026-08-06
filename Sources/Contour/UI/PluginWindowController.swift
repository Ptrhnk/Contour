import AppKit
import AVFoundation
import CoreAudioKit
import Observation
import SwiftUI
import os

/// Hosts plugin editors in their own windows, so the popover can close without
/// taking them with it (§6).
///
/// Windows are kept once created rather than rebuilt. Closing one used to drop
/// it, so reopening asked the unit for a *second* view controller — which some
/// plugins do not survive; SoundID Reference hangs on the second open.
@MainActor
@Observable
final class PluginWindowController {

    static let shared = PluginWindowController()

    /// Which editors are on screen, so the button that opens them can show it.
    private(set) var openItems: Set<UUID> = []

    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var observers: [UUID: any NSObjectProtocol] = [:]

    private static let log = Logger(subsystem: "com.nahak.contour", category: "pluginwindow")

    func isOpen(_ itemID: UUID) -> Bool { openItems.contains(itemID) }

    /// Open, or close it again if it is already showing.
    func toggle(item: ProcessingItem, chain: Chain, engine: AudioEngine) {
        if isOpen(item.id) {
            windows[item.id]?.close()
            openItems.remove(item.id)
        } else {
            show(item: item, chain: chain, engine: engine)
        }
    }

    func show(item: ProcessingItem, chain: Chain, engine: AudioEngine) {
        if let existing = windows[item.id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            openItems.insert(item.id)
            return
        }
        guard let host = engine.pluginHost(for: item, chain: chain) else {
            Self.log.error("no live host for \(item.title, privacy: .public)")
            return
        }

        host.audioUnit.requestViewController { [weak self] controller in
            MainActor.assumeIsolated {
                guard let self else { return }
                let content = controller
                    ?? NSHostingController(rootView: GenericPluginView(host: host))
                let window = NSWindow(contentViewController: content)
                window.title = item.title
                window.styleMask = [.titled, .closable, .resizable]
                window.isReleasedWhenClosed = false
                window.center()
                self.windows[item.id] = window

                self.observers[item.id] = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main) { _ in
                        MainActor.assumeIsolated {
                            // A plugin's settings live inside it until asked for.
                            engine.capturePluginStates(for: chain)
                            self.openItems.remove(item.id)
                        }
                    }

                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                self.openItems.insert(item.id)
            }
        }
    }

    /// Called when a plugin leaves the chain: only then is its editor finished
    /// with, and only then may the view controller be released.
    func discard(itemID: UUID) {
        windows[itemID]?.close()
        windows[itemID] = nil
        if let observer = observers.removeValue(forKey: itemID) {
            NotificationCenter.default.removeObserver(observer)
        }
        openItems.remove(itemID)
    }
}

/// Fallback editor: the unit's parameters as plain sliders.
private struct GenericPluginView: View {
    let host: PluginHost

    private var parameters: [AUParameter] {
        host.audioUnit.parameterTree?.allParameters ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if parameters.isEmpty {
                    Text("This plugin exposes no parameters.")
                        .foregroundStyle(.secondary)
                }
                ForEach(parameters, id: \.address) { parameter in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(parameter.displayName).font(.caption)
                            Spacer()
                            Text(parameter.string(fromValue: nil))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(parameter.value) },
                            set: { parameter.value = AUValue($0) }),
                               in: Double(parameter.minValue)...Double(parameter.maxValue))
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
    }
}
