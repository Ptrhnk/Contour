import AppKit
import SwiftUI

@main
struct ContourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: delegate.engine, launchAgent: delegate.launchAgent)
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

    /// launchd execs the binary directly rather than going through
    /// LaunchServices, so opening the app from Finder while the watchdog's copy
    /// is running would start a *second* instance — two engines building two
    /// aggregate devices over the same hardware.
    ///
    /// First one wins. At login launchd is always first, so the survivor is the
    /// one the watchdog is actually watching. Exits zero so KeepAlive treats it
    /// as a clean exit and does not respawn.
    private func terminateIfAlreadyRunning() {
        let me = NSRunningApplication.current
        let duplicate = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == me.bundleIdentifier
                && $0.processIdentifier != me.processIdentifier
        }
        guard duplicate else { return }
        NSLog("Contour is already running; this instance is exiting.")
        exit(0)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        terminateIfAlreadyRunning()
    }
    let engine = AudioEngine()
    /// Owned here rather than by the popover: the agent repairs its registration
    /// on launch, which must happen whether or not the popover is ever opened.
    let launchAgent = LaunchAgent()

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
