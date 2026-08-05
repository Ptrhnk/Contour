import AppKit
import Observation
import ServiceManagement
import os

/// Launch at login, via `SMAppService.mainApp`.
///
/// Worth more here than convenience: with BlackHole as the system output
/// device, Contour not running means nothing drains it, and there is no sound
/// at all.
///
/// Registration records the bundle's current location, so a build that moves
/// house needs re-registering. Rebuilding in place is fine.
@MainActor
@Observable
final class LoginItem {

    private(set) var status: SMAppService.Status
    private(set) var failure: String?

    private static let log = Logger(subsystem: "com.nahak.contour", category: "loginitem")

    init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    /// macOS can hold registration pending until the user approves it in
    /// Login Items, in which case the toggle looks on but nothing happens.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = "\(error.localizedDescription)"
            Self.log.error("""
                login item \(enabled ? "register" : "unregister", privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
        }
        refresh()
    }

    func openLoginItemsSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
