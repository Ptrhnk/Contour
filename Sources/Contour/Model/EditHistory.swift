import Foundation
import Observation

/// Undo/redo over whole-chain snapshots.
///
/// Edits arrive continuously — a curve drag produces a change per frame — so
/// entries coalesce while changes keep arriving for the same chain. One drag,
/// one knob sweep or one burst of typing therefore becomes a single undo step,
/// which is what "undo" is expected to mean.
@MainActor
@Observable
final class EditHistory {

    private struct Entry {
        let chain: Chain
        let before: ChainSettings
        var after: ChainSettings
    }

    /// A pause longer than this starts a new undo step.
    private static let coalescingWindow: TimeInterval = 0.6
    private static let limit = 100

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var lastRecordedAt: Date?

    /// Set while an undo or redo is being applied, so the resulting change is
    /// not recorded as a fresh edit.
    private(set) var isApplying = false

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }

    func record(chain: Chain, before: ChainSettings, after: ChainSettings) {
        guard !isApplying, before != after else { return }

        let now = Date()
        if var top = undoEntries.last,
           top.chain == chain,
           let last = lastRecordedAt,
           now.timeIntervalSince(last) < Self.coalescingWindow {
            top.after = after
            undoEntries[undoEntries.count - 1] = top
        } else {
            undoEntries.append(Entry(chain: chain, before: before, after: after))
            if undoEntries.count > Self.limit { undoEntries.removeFirst() }
        }
        lastRecordedAt = now
        redoEntries.removeAll()
    }

    /// Returns the chain to restore and the settings to restore into it.
    func undo() -> (chain: Chain, settings: ChainSettings)? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(entry)
        lastRecordedAt = nil
        return (entry.chain, entry.before)
    }

    func redo() -> (chain: Chain, settings: ChainSettings)? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(entry)
        lastRecordedAt = nil
        return (entry.chain, entry.after)
    }

    func withApplying(_ body: () -> Void) {
        isApplying = true
        body()
        isApplying = false
    }

    func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
        lastRecordedAt = nil
    }
}
