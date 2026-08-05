import AppKit
import SwiftUI

@main
struct ContourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: delegate.engine)
        } label: {
            // The icon answers "where is the sound going" without opening anything.
            Image(systemName: delegate.engine.status.isRunning
                  ? delegate.engine.destination.symbol
                  : "waveform.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = AudioEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}
