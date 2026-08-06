import SwiftUI

/// Preset menu for one chain, plus save / rename / delete.
///
/// Naming happens inline rather than in a sheet: the popover is a transient
/// window and presenting a modal over it fights the dismiss-on-outside-click
/// behaviour.
struct PresetBar: View {
    @Bindable var engine: AudioEngine
    let chain: Chain

    private enum Editing: Equatable {
        case none
        case creating
        case renaming(UUID)
    }

    @State private var editing: Editing = .none
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var loaded: Preset? { engine.loadedPreset(for: chain) }
    private var isDirty: Bool { engine.hasUnsavedChanges(chain) }

    var body: some View {
        Group {
            if editing == .none {
                controls
            } else {
                nameEditor
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
                Button("Save as New…") { beginCreating() }
                if let loaded {
                    Button("Rename “\(loaded.name)”…") { beginRenaming(loaded) }
                    Button("Delete “\(loaded.name)”", role: .destructive) {
                        engine.deletePreset(loaded.id)
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
            Button {
                beginCreating()
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.small)
            .help("Save the current settings as a new preset")
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

    private func beginCreating() {
        draftName = suggestedName()
        editing = .creating
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
        case .creating:
            engine.savePresetAsNew(named: name, from: chain)
        case .renaming(let id):
            engine.presets.rename(id: id, to: name)
        case .none:
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
