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
        Window(EQWindowView.windowTitle, id: EQWindowView.id) {
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

    /// Right-click on the menu bar icon offers Quit.
    ///
    /// `MenuBarExtra` does not expose its `NSStatusItem`, so there is nothing to
    /// hang a context menu on. Instead a local event monitor catches the right
    /// click before it reaches the status item and returns nil to consume it, so
    /// the popover does not open as well.
    private var statusItemRightClickMonitor: Any?

    private func installStatusItemContextMenu() {
        statusItemRightClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  let window = event.window,
                  NSStringFromClass(type(of: window)).contains("StatusBarWindow"),
                  let view = window.contentView
            else { return event }
            self.showStatusItemMenu(over: view)
            return nil
        }
    }

    private func showStatusItemMenu(over view: NSView) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Contour",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: view.bounds.height + 4),
                   in: view)
    }
    let engine = AudioEngine()
    /// Owned here rather than by the popover: the agent repairs its registration
    /// on launch, which must happen whether or not the popover is ever opened.
    let launchAgent = LaunchAgent()

    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces alongside the Info.plist keys: the EQ window is
        // incidental, the audio engine is the point, so the process must
        // outlive every window.
        ProcessInfo.processInfo.disableAutomaticTermination("Contour renders audio continuously")
        installStatusItemContextMenu()
        // Warm the plugin list now rather than when the picker is first opened,
        // where the wait is in the way.
        engine.catalog.scanIfNeeded()
        engine.start()
        installTerminationSignalHandlers()
    }

    /// launchd sends `SIGTERM` at logout, and the default disposition kills the
    /// process without ever reaching `applicationWillTerminate`. Measured: even a
    /// `SIGKILL` leaves no tap behind and audio returns by itself, so this is not
    /// what makes the mute safe — it just makes the exit orderly.
    private func installTerminationSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Plugin settings live inside the plugin until asked for.
        for chain in Chain.allCases { engine.capturePluginStates(for: chain) }
        engine.stop()
    }
}
