import Foundation
import Observation
import os

/// A full snapshot of one chain: EQ bands, Adapt. Q, input trim, auto-trim and
/// output gain.
///
/// Deliberately **not** per chain, which is where this departs from the spec.
/// A pair of headphones can arrive on chain B through the interface's 3/4 pair
/// or, over Bluetooth, as a stereo-only device that renders on chain A. Keeping
/// separate lists would hide a headphone curve from half the ways you can plug
/// those headphones in.
struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var settings: ChainSettings

    init(id: UUID = UUID(), name: String, settings: ChainSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

/// Presets on disk. JSON in Application Support.
///
/// Once plugins land these become non-portable — plugin state is opaque binary
/// that only restores on a machine with the same plugins installed. The
/// shareable artefact stays the EQ curve alone, as AutoEq text (§5.6).
@MainActor
@Observable
final class PresetStore {

    private(set) var presets: [Preset] = []

    private static let log = Logger(subsystem: "com.nahak.contour", category: "presets")

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Contour", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("presets.json")
        reload()
    }

    func preset(id: UUID?) -> Preset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, settings: ChainSettings) -> Preset {
        let preset = Preset(name: uniqueName(from: name), settings: settings)
        presets.append(preset)
        persist()
        return preset
    }

    func update(id: UUID, settings: ChainSettings) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].settings = settings
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets[index].name = trimmed
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    /// Keeps names distinct so the menu stays readable.
    private func uniqueName(from proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        guard presets.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while presets.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }

    private func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            presets = try JSONDecoder().decode([Preset].self, from: data)
        } catch {
            // Keep the unreadable file rather than overwriting someone's presets
            // with an empty list.
            Self.log.error("could not read presets: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("could not write presets: \(String(describing: error), privacy: .public)")
        }
    }
}
