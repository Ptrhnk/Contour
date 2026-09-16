import CryptoKit
import Foundation
import os

/// Plugin state blobs, content-addressed, as files in Application Support.
///
/// `fullStateForDocument` is large — SoundID Reference's is 2.8 MB — and it
/// used to sit inline in `ChainSettings`. That put it in `UserDefaults`, and
/// since `chainA.didSet` saves the whole struct, every EQ drag update
/// re-encoded the blob and rewrote it. Measured, with that plugin in the chain:
///
///     chain save with the blob inline    7.3 ms, 3,729,890 bytes written
///     chain save with a reference        0.0 ms,        46 bytes written
///
/// 7.3 ms of a 33 ms frame, on the main thread, spent rewriting bytes that had
/// not changed. `Equatable` paid the same toll twice over: the `chainA !=
/// oldValue` guard in the observer, and the `state != item.state` check in
/// `capturePluginStates`, both compared megabytes.
///
/// Naming a blob by the SHA-256 of its contents fixes all three at once.
/// Writes are idempotent, so storing an unchanged state writes nothing.
/// Identical settings shared by a chain and any number of presets are stored
/// once. And "did this change?" becomes a string comparison.
///
/// The blobs are deliberately *not* reachable from `ProcessingItem` as a
/// computed property: reading one is disk I/O, and hiding that behind a
/// property access is how it would end up on the audio path by accident.
enum PluginStateStore {

    private static let log = Logger(subsystem: "com.nahak.contour", category: "pluginstate")

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base
            .appendingPathComponent("Contour", isDirectory: true)
            .appendingPathComponent("PluginState", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func url(for reference: String) -> URL {
        directory.appendingPathComponent(reference).appendingPathExtension("bin")
    }

    /// Stores the blob if it is not already there, and returns its reference.
    ///
    /// Idempotent, because the name *is* the content. Storing a state that has
    /// not changed since the last capture touches the disk exactly once, to ask
    /// whether the file exists.
    static func store(_ data: Data) -> String? {
        let reference = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = url(for: reference)
        guard !FileManager.default.fileExists(atPath: url.path) else { return reference }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("""
                could not write plugin state: \(String(describing: error), privacy: .public)
                """)
            return nil
        }
        return reference
    }

    /// Nil where the blob has gone — a hand-cleaned Application Support, say.
    /// Callers treat that as a plugin with no saved settings rather than as a
    /// failure: a plugin at its defaults is something the user can fix, a chain
    /// that refuses to load is not.
    static func load(_ reference: String) -> Data? {
        guard let data = try? Data(contentsOf: url(for: reference)) else {
            log.error("""
                plugin state \(reference, privacy: .public) is missing; \
                loading that plugin at its defaults
                """)
            return nil
        }
        return data
    }

    /// Deletes blobs nothing points at any more.
    ///
    /// Every change to a plugin's settings stores a new blob and orphans the
    /// one before it, at 2.8 MB a time for SoundID Reference, so without this
    /// the directory grows for as long as the app is used. Swept at launch,
    /// which is the one moment with no capture in flight — the store has no
    /// other writers to race there.
    ///
    /// Only files this store could have written are considered, so anything
    /// else that ends up in the directory is left alone rather than deleted.
    static func collectGarbage(keeping references: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        var removed = 0
        var reclaimed = 0
        for name in names where name.hasSuffix(".bin") {
            let reference = String(name.dropLast(4))
            guard reference.count == 64, reference.allSatisfy(\.isHexDigit),
                  !references.contains(reference)
            else { continue }
            let url = directory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? Int ?? 0
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            removed += 1
            reclaimed += size
        }
        if removed > 0 {
            log.notice("""
                removed \(removed, privacy: .public) unreferenced plugin state file(s), \
                \(reclaimed, privacy: .public) bytes
                """)
        }
    }
}
