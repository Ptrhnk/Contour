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

        // A real window, so it can be centred and resized — the menu-bar panel
        // offers no placement control.
        Window("Contour EQ", id: EQWindowView.id) {
            EQWindowView(engine: delegate.engine)
        }
        .defaultSize(width: 900, height: 620)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = AudioEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside the Info.plist keys: the EQ window is
        // incidental, the audio engine is the point, so the process must
        // outlive every window.
        ProcessInfo.processInfo.disableAutomaticTermination("Contour renders audio continuously")
        engine.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}
