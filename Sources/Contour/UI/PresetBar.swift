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
                HStack(spacing: 4) {
                    Text(loaded?.name ?? "No preset")
                        .foregroundStyle(loaded == nil ? .secondary : .primary)
                    if isDirty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
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
        loaded.map { "\($0.name) copy" } ?? "Preset \(engine.presets.presets.count + 1)"
    }
}
