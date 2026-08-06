import AppKit
import AVFoundation
import CoreAudioKit
import SwiftUI
import os

/// Hosts a plugin's own interface in a separate `NSWindow`, so the popover can
/// close without taking the editor with it (§6).
@MainActor
final class PluginWindowController {

    private static var windows: [UUID: NSWindow] = [:]
    private static let log = Logger(subsystem: "com.nahak.contour", category: "pluginwindow")

    static func show(item: ProcessingItem, chain: Chain, engine: AudioEngine) {
        if let existing = windows[item.id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let host = engine.pluginHost(for: item, chain: chain) else {
            log.error("no live host for \(item.title, privacy: .public)")
            return
        }

        host.audioUnit.requestViewController { controller in
            MainActor.assumeIsolated {
                let content: NSViewController
                if let controller {
                    content = controller
                } else {
                    // Plenty of units have no custom view. A generic parameter
                    // list is still better than nothing.
                    content = NSHostingController(
                        rootView: GenericPluginView(host: host))
                }
                let window = NSWindow(contentViewController: content)
                window.title = item.title
                window.styleMask = [.titled, .closable, .resizable]
                window.isReleasedWhenClosed = false
                window.center()
                windows[item.id] = window

                // The window is kept, not discarded. Closing it used to drop the
                // entry, so reopening asked the unit for a *second* view
                // controller — which some plugins do not survive; SoundID
                // Reference hangs on the second open. Reopening now just orders
                // the same window front again.
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main) { _ in
                        MainActor.assumeIsolated {
                            engine.capturePluginStates(for: chain)
                        }
                    }

                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Called when a plugin leaves the chain: only then is its editor really
    /// finished with.
    static func discard(itemID: UUID) {
        windows[itemID]?.close()
        windows[itemID] = nil
    }

    static func closeAll() {
        for window in windows.values { window.close() }
        windows.removeAll()
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
