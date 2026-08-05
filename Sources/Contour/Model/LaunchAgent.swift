import AppKit
import Observation
import ServiceManagement
import os

/// Launch at login **and** crash restart, through one bundled LaunchAgent.
///
/// `SMAppService.mainApp` would give launch-at-login alone. The agent plist adds
/// `KeepAlive { SuccessfulExit = false }`, which is the watchdog: quitting from
/// the menu exits zero and stays quit, while an abnormal exit brings the app
/// straight back.
///
/// That matters because plugins are hosted in-process by design — out-of-process
/// isolation adds IPC jitter a realtime insert cannot absorb — so a third-party
/// AU that segfaults takes Contour with it. And since BlackHole is the system
/// output with nothing else draining it, a dead Contour is silence rather than
/// merely unprocessed audio.
@MainActor
@Observable
final class LaunchAgent {

    static let plistName = "com.nahak.contour.agent.plist"

    private(set) var status: SMAppService.Status
    private(set) var failure: String?

    private static let log = Logger(subsystem: "com.nahak.contour", category: "launchagent")

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    init() {
        status = SMAppService.agent(plistName: Self.plistName).status
        migrateFromMainApp()
    }

    var isEnabled: Bool { status == .enabled }

    /// macOS can hold registration pending until the user approves it in Login
    /// Items, in which case the toggle looks on but nothing runs.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            failure = error.localizedDescription
            Self.log.error("""
                \(enabled ? "register" : "unregister", privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
        }
        refresh()
    }

    /// Earlier builds registered `SMAppService.mainApp`. Leaving that in place
    /// alongside the agent would start the app twice at login.
    private func migrateFromMainApp() {
        guard SMAppService.mainApp.status == .enabled else { return }
        Self.log.notice("migrating login item from mainApp to the launch agent")
        try? SMAppService.mainApp.unregister()
        setEnabled(true)
    }

    func openLoginItemsSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
