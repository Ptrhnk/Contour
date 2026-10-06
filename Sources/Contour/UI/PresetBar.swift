import SwiftUI

/// Preset menu for one chain, plus new / duplicate / save / rename / delete.
///
/// Naming happens inline rather than in a sheet: the popover is a transient
/// window and presenting a modal over it fights the dismiss-on-outside-click
/// behaviour.
struct PresetBar: View {
    @Bindable var engine: AudioEngine
    let chain: Chain

    private enum Editing: Equatable {
        case none
        /// Snapshot of the chain as it stands.
        case duplicating
        /// Same chain with the EQ cleared.
        case creatingClear
        case renaming(UUID)
        /// Deleting cannot be undone, so the trash button asks first — inline,
        /// for the same reason naming is inline.
        case confirmingDelete(UUID)
    }

    @State private var editing: Editing = .none
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var loaded: Preset? { engine.loadedPreset(for: chain) }
    private var isDirty: Bool { engine.hasUnsavedChanges(chain) }

    var body: some View {
        Group {
            switch editing {
            case .none: controls
            case .confirmingDelete(let id): deleteConfirmation(id)
            default: nameEditor
            }
        }
    }

    // MARK: - Normal state

    private var controls: some View {
        HStack(spacing: 6) {
            Menu {
                if engine.presets.presets.isEmpty {
                    Text("No presets yet")
                } else {
                    ForEach(Array(engine.presets.presets.enumerated()), id: \.element.id) {
                        index, preset in
                        Button {
                            engine.loadPreset(preset, into: chain)
                        } label: {
                            if preset.id == loaded?.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                        // Number keys for the first nine slots.
                        .keyboardShortcut(index < 9
                                          ? KeyEquivalent(Character("\(index + 1)"))
                                          : .clear)
                    }
                }
                Divider()
                Button("New with Clear EQ…") { beginCreatingClear() }
                Button(loaded == nil ? "Save as New…" : "Duplicate…") { beginDuplicating() }
                if let loaded {
                    Button("Rename “\(loaded.name)”…") { beginRenaming(loaded) }
                    Button("Delete “\(loaded.name)”…", role: .destructive) {
                        editing = .confirmingDelete(loaded.id)
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(loaded?.name ?? "No preset")
                        .foregroundStyle(loaded == nil ? .secondary : .primary)
                    // Conventional "modified" marker. Silently discarding an
                    // hour of tweaking on a preset switch is what makes a tool
                    // untrustworthy, so the state has to be visible.
                    if isDirty {
                        Text("*")
                            .foregroundStyle(.orange)
                            .help("Unsaved changes")
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()

            Spacer()

            if loaded != nil {
                Button("Save") { engine.updateLoadedPreset(from: chain) }
                    .controlSize(.small)
                    .disabled(!isDirty)
                    .help("Overwrite this preset with the current settings")
            }
            if let loaded {
                Button {
                    editing = .confirmingDelete(loaded.id)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Delete this preset")
                Button {
                    beginDuplicating()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .controlSize(.small)
                .help("Duplicate this preset, including any unsaved changes")
            }
            Button {
                beginCreatingClear()
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.small)
            .help("New preset with a clear EQ and auto trim. Plugins and output gain are kept.")
        }
    }

    // MARK: - Naming

    private var nameEditor: some View {
        HStack(spacing: 6) {
            TextField("Preset name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($nameFocused)
                .onSubmit(commit)
            Button("Cancel") { editing = .none }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: commit)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func deleteConfirmation(_ id: UUID) -> some View {
        HStack(spacing: 6) {
            Text("Delete “\(engine.presets.preset(id: id)?.name ?? "preset")”?")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Cancel") { editing = .none }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) {
                engine.deletePreset(id)
                editing = .none
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func beginDuplicating() {
        draftName = suggestedName()
        editing = .duplicating
        nameFocused = true
    }

    private func beginCreatingClear() {
        draftName = Self.uniqueName("Preset \(engine.presets.presets.count + 1)",
                                    avoiding: engine.presets.presets.map(\.name))
        editing = .creatingClear
        nameFocused = true
    }

    private func beginRenaming(_ preset: Preset) {
        draftName = preset.name
        editing = .renaming(preset.id)
        nameFocused = true
    }

    private func commit() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch editing {
        case .duplicating:
            engine.savePresetAsNew(named: name, from: chain)
        case .creatingClear:
            engine.createPresetWithClearEQ(named: name, for: chain)
        case .renaming(let id):
            engine.presets.rename(id: id, to: name)
        case .none, .confirmingDelete:
            break
        }
        editing = .none
    }

    private func suggestedName() -> String {
        guard let loaded else { return "Preset \(engine.presets.presets.count + 1)" }
        return Self.nextName(after: loaded.name,
                             avoiding: engine.presets.presets.map(\.name))
    }

    /// Increments a trailing number, keeping its width: "NOIRE XO 01" becomes
    /// "NOIRE XO 02", not "NOIRE XO 2" or "NOIRE XO 01 copy". Iterating a
    /// numbered series is the usual reason to save a preset as new, so that is
    /// what the field should already say.
    ///
    /// Skips names already taken, so it lands on the next free number rather
    /// than colliding and being renamed by the store.
    static func nextName(after name: String, avoiding taken: [String]) -> String {
        let trailingDigits = String(name.reversed().prefix { $0.isNumber }.reversed())
        guard !trailingDigits.isEmpty, let start = Int(trailingDigits) else {
            return uniqueName("\(name) copy", avoiding: taken)
        }
        let stem = String(name.dropLast(trailingDigits.count))
        let width = trailingDigits.count

        for value in (start + 1)...(start + 999) {
            // Zero padding only holds while the number fits the original width;
            // 09 goes to 10, and 99 to 100 rather than being truncated.
            let candidate = stem + String(format: "%0\(width)d", value)
            if !taken.contains(candidate) { return candidate }
        }
        return uniqueName("\(name) copy", avoiding: taken)
    }

    private static func uniqueName(_ proposed: String, avoiding taken: [String]) -> String {
        guard taken.contains(proposed) else { return proposed }
        var index = 2
        while taken.contains("\(proposed) \(index)") { index += 1 }
        return "\(proposed) \(index)"
    }
}
