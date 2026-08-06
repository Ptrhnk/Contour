import AppKit
import Foundation
import Observation
import ServiceManagement
import os

/// Launch at login **and** crash restart, through a launchd user agent.
///
/// `KeepAlive { SuccessfulExit = false }` is the watchdog: quitting from the
/// menu exits zero and stays quit, while an abnormal exit brings the app back in
/// a few seconds. That matters because plugins are hosted in-process by design —
/// out-of-process isolation adds IPC jitter a realtime insert cannot absorb — so
/// a third-party AU that segfaults takes Contour with it, and since BlackHole is
/// the system output with nothing else draining it, a dead Contour is silence
/// rather than merely unprocessed audio.
///
/// **Why not `SMAppService`.** The modern API refuses a self-signed build.
/// launchd derives a lightweight code requirement for the bundle and fails:
///
///     Service could not initialize: Unable to get updated LWCR for (…),
///     error 0x16 - Invalid argument
///     job state = spawn failed, last exit reason = OS_REASON_CODESIGNING
///
/// That machinery wants a trusted signature, and this project commits to a
/// self-signed certificate with no Developer Program (§8a). A plain agent in
/// `~/Library/LaunchAgents` predates LWCR and works: measured restarting after
/// `kill -9` in about three seconds.
@MainActor
@Observable
final class LaunchAgent {

    /// Labels are generational, and that is not decoration.
    ///
    /// A launchd label that has been bootstrapped and then booted out cannot be
    /// bootstrapped again in the same login session: the command reports success
    /// and the job silently never loads. `launchctl enable` and `kickstart` do
    /// not recover it, and neither does deleting and rewriting the plist. A
    /// label that has never been used loads immediately.
    ///
    /// So each install claims a fresh label and the previous one is retired.
    /// Turning the toggle off and on again therefore keeps working, instead of
    /// appearing to succeed while leaving no watchdog at all.
    private static let labelPrefix = "com.nahak.contour.watchdog"

    /// Labels used before the generational scheme, cleaned up on launch.
    private static let retiredLabels = ["com.nahak.contour.agent",
                                        "com.nahak.contour.watchdog"]

    private static let generationKey = "watchdogGeneration"

    private(set) var isEnabled: Bool = false
    private(set) var failure: String?

    private static let log = Logger(subsystem: "com.nahak.contour", category: "launchagent")

    private let agentsDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    private var generation: Int {
        get { UserDefaults.standard.integer(forKey: Self.generationKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.generationKey) }
    }

    private var label: String { "\(Self.labelPrefix).\(generation)" }
    private var plistURL: URL { agentsDirectory.appendingPathComponent("\(label).plist") }
    private var domain: String { "gui/\(getuid())" }

    init() {
        isEnabled = FileManager.default.fileExists(atPath: plistURL.path)
        retireServiceManagementRegistrations()
        refreshRegistration()
    }

    func refresh() {
        isEnabled = FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        do {
            if enabled {
                try install()
            } else {
                retire(label: label, plist: plistURL)
            }
        } catch {
            failure = error.localizedDescription
            Self.log.error("""
                \(enabled ? "install" : "remove", privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
        }
        refresh()
    }

    /// Reinstalls only when something has actually changed.
    ///
    /// Re-bootstrapping a healthy job would mean booting it out first, which is
    /// the one thing that permanently breaks the label. So the happy path — same
    /// executable path, job still loaded — does nothing at all.
    private func refreshRegistration() {
        guard isEnabled else { return }
        if isLoaded, installedExecutablePath == currentExecutablePath { return }
        Self.log.notice("launch agent needs reinstalling (loaded: \(self.isLoaded, privacy: .public))")
        do {
            try install()
        } catch {
            Self.log.error("refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var currentExecutablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
    }

    private var installedExecutablePath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return nil }
        return arguments.first
    }

    private var isLoaded: Bool {
        ((try? launchctl(["print", "\(domain)/\(label)"])) ?? 1) == 0
    }

    /// Retires the current label and claims the next one.
    private func install() throws {
        retire(label: label, plist: plistURL)
        generation += 1

        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [currentExecutablePath],
            "RunAtLoad": true,
            // Restart only on abnormal exit, so Quit stays quit.
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(at: agentsDirectory,
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: contents,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: plistURL, options: .atomic)
        try launchctl(["bootstrap", domain, plistURL.path])
        Self.log.notice("launch agent installed as \(self.label, privacy: .public)")
    }

    private func retire(label: String, plist: URL) {
        // Fails harmlessly when the job was never loaded.
        _ = try? launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "com.nahak.contour.launchctl",
                          code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "launchctl \(arguments.first ?? "") failed "
                            + "(\(process.terminationStatus))"])
        }
        return process.terminationStatus
    }

    /// Earlier builds used `SMAppService`, and a `.agent` registration that
    /// could never spawn. Leaving those behind starts the app twice at login or
    /// keeps a broken job retrying every ten seconds forever.
    private func retireServiceManagementRegistrations() {
        if SMAppService.mainApp.status == .enabled {
            Self.log.notice("removing the old SMAppService login item")
            try? SMAppService.mainApp.unregister()
        }
        let bundled = SMAppService.agent(plistName: "com.nahak.contour.agent.plist")
        if bundled.status == .enabled || bundled.status == .requiresApproval {
            Self.log.notice("removing the old SMAppService agent registration")
            try? bundled.unregister()
        }

        for retired in Self.retiredLabels {
            let url = agentsDirectory.appendingPathComponent("\(retired).plist")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            Self.log.notice("retiring \(retired, privacy: .public)")
            retire(label: retired, plist: url)
            // Their presence was how "enabled" used to be detected.
            isEnabled = true
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
