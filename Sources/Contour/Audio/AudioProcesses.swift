import AppKit
import CoreAudio
import Foundation

/// One app that can be left out of the tap's capture.
struct ExcludableApp: Identifiable, Hashable, Sendable {
    /// The application's bundle identifier, which is what gets persisted.
    /// Process object IDs are not stable across launches; this is.
    let bundleID: String
    var name: String
    /// Whether anything under this bundle ID is registered with the HAL right
    /// now. A persisted exclusion for an app that is not running stays listed
    /// so it can be turned back off.
    var isPresent: Bool

    var id: String { bundleID }
}

/// The HAL's view of which processes make sound.
///
/// Used only to build the tap's exclusion list, which is why everything here is
/// keyed by bundle ID rather than by the `AudioObjectID`s the tap actually
/// wants: object IDs and PIDs both change every launch, and an exclusion has to
/// survive a restart of Contour *and* of the app it excludes.
enum AudioProcesses {

    /// Every audio process object the HAL currently knows about, as
    /// `(object, bundleID)`. Processes with no bundle ID are dropped — there is
    /// nothing to persist for them.
    static func all() -> [(object: AudioObjectID, bundleID: String)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let objects = (try? CA.array(system,
                                     CA.address(kAudioHardwarePropertyProcessObjectList),
                                     of: AudioObjectID.self)) ?? []
        return objects.compactMap { object in
            guard object != 0,
                  let bundleID = CA.string(object, CA.address(kAudioProcessPropertyBundleID)),
                  !bundleID.isEmpty
            else { return nil }
            return (object, bundleID)
        }
    }

    /// The process objects to hand `CATapDescription` for a set of excluded apps.
    ///
    /// Matching is by bundle ID **or a dotted prefix of one**, because a browser
    /// does not play its audio from the process that carries the app's bundle
    /// ID: Chrome renders from `com.google.Chrome.helper`, and excluding
    /// "Google Chrome" has to catch those too.
    ///
    /// Resolution is deliberately lenient. An excluded app that is not running
    /// contributes nothing rather than failing the tap — otherwise quitting
    /// Ableton would take the whole engine down with it.
    static func objects(excluding bundleIDs: Set<String>) -> [AudioObjectID] {
        guard !bundleIDs.isEmpty else { return [] }
        return all().filter { matches($0.bundleID, bundleIDs) }.map(\.object)
    }

    static func matches(_ bundleID: String, _ excluded: Set<String>) -> Bool {
        excluded.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// What to offer in the picker: ordinary apps — the ones with a Dock icon —
    /// that have registered with the HAL, plus any already-excluded bundle ID
    /// whose app is not running, so an exclusion can always be undone.
    ///
    /// Helper processes are folded into their app by the same prefix rule used
    /// to resolve them, so the list reads as applications rather than as the
    /// HAL's process table.
    static func excludableApps(alwaysIncluding excluded: Set<String>) -> [ExcludableApp] {
        var byBundleID: [String: ExcludableApp] = [:]

        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        let presentBundleIDs = Set(all().map(\.bundleID))

        for app in running {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }
            // Present if the app itself is registered, or any of its helpers is.
            let isPresent = presentBundleIDs.contains {
                $0 == bundleID || $0.hasPrefix(bundleID + ".")
            }
            guard isPresent || excluded.contains(bundleID) else { continue }
            byBundleID[bundleID] = ExcludableApp(bundleID: bundleID,
                                                 name: app.localizedName ?? bundleID,
                                                 isPresent: isPresent)
        }

        // Excluded but not running: keep it visible, marked absent.
        for bundleID in excluded where byBundleID[bundleID] == nil {
            byBundleID[bundleID] = ExcludableApp(bundleID: bundleID,
                                                 name: displayName(for: bundleID),
                                                 isPresent: false)
        }

        return byBundleID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Best effort name for an app that is not running: LaunchServices still
    /// knows where it lives, so an exclusion reads as "Ableton Live 12 Suite"
    /// rather than as a reverse-DNS string.
    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}
