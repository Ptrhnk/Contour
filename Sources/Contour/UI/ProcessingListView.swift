import SwiftUI
import UniformTypeIdentifiers

/// The ordered processing list for one chain: the EQ and any plugins, dragged
/// into whatever order you want.
///
/// The EQ is one of the rows rather than a fixed stage, which is what makes
/// "before or after this plugin" a drag rather than a mode (§4).
struct ProcessingListView: View {
    @Bindable var engine: AudioEngine
    let chain: Chain

    @State private var showingPicker = false
    @State private var search = ""
    @State private var dropTarget: UUID?

    private var settings: Binding<ChainSettings> {
        chain == .a ? $engine.chainA : $engine.chainB
    }

    private var items: [ProcessingItem] { settings.wrappedValue.processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processing").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if engine.pluginLatencyFrames[chain, default: 0] > 0, engine.sampleRate > 0 {
                    let ms = Double(engine.pluginLatencyFrames[chain, default: 0])
                        / engine.sampleRate * 1000
                    Text(String(format: "+%.1f ms", ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Plugin latency in this chain. It affects video sync "
                              + "within the chain; there is deliberately no "
                              + "compensation between chains.")
                }
                Button {
                    engine.catalog.scanIfNeeded()
                    showingPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Add a plugin")
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    pluginPicker
                }
            }

            ForEach(items) { item in
                row(item)
            }

            if let failure = engine.pluginFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rows

    private func row(_ item: ProcessingItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")

            PowerToggle(isOn: bypassBinding(item), diameter: 16)
                .help(item.isEQ
                      ? "EQ on or off"
                      : (item.isBypassed
                         ? "Bypassed — no audio passes through it"
                         : "Active"))

            Text(item.title)
                .font(.caption)
                .foregroundStyle(item.isBypassed ? .secondary : .primary)
                .lineLimit(1)

            Spacer()

            if !item.isEQ {
                Button {
                    PluginWindowController.show(item: item, chain: chain, engine: engine)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .help("Open the plugin's own interface")

                Button {
                    remove(item)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove")
            }

            // Kept alongside dragging: one step is quicker to aim at than a
            // drag, and dragging is fiddly in a popover this narrow.
            Button {
                move(item, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(items.first?.id == item.id)
            .help("Move earlier in the chain")

            Button {
                move(item, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(items.last?.id == item.id)
            .help("Move later in the chain")
        }
        .font(.caption)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(dropTarget == item.id
                    ? Color.accentColor.opacity(0.25)
                    : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        // Order is the signal path, so dragging a row is the direct way to say
        // "run this before that" — including moving a plugin above or below the
        // EQ, which is the whole point of the EQ being a row (§4).
        .draggable(item.id.uuidString) {
            Text(item.title).font(.caption).padding(4)
        }
        .dropDestination(for: String.self) { payload, _ in
            guard let raw = payload.first, let dragged = UUID(uuidString: raw) else { return false }
            dropTarget = nil
            return move(dragged, before: item.id)
        } isTargeted: { targeted in
            dropTarget = targeted ? item.id : (dropTarget == item.id ? nil : dropTarget)
        }
    }

    private var pluginPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if engine.catalog.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.caption)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(matching) { descriptor in
                        Button {
                            add(descriptor)
                            showingPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(descriptor.name).font(.caption)
                                Text(descriptor.manufacturer)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(10)
        .frame(width: 280)
    }

    private var matching: [AudioUnitDescriptor] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return engine.catalog.effects }
        return engine.catalog.effects.filter {
            $0.name.lowercased().contains(query) || $0.manufacturer.lowercased().contains(query)
        }
    }

    // MARK: - Mutation

    private func bypassBinding(_ item: ProcessingItem) -> Binding<Bool> {
        // The EQ's real on/off is `eq.isEnabled`; the row must drive that rather
        // than the item's own bypass flag, which nothing downstream reads.
        guard !item.isEQ else {
            return Binding(get: { settings.wrappedValue.eq.isEnabled },
                           set: { settings.wrappedValue.eq.isEnabled = $0 })
        }
        return Binding(
            get: { !item.isBypassed },
            set: { active in
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
                engine.capturePluginStates(for: chain)
                settings.wrappedValue.processing[index].isBypassed = !active
            })
    }

    /// Every mutation captures live plugin state first. Changing the list
    /// rebuilds the graph, and the rebuild reapplies each item's stored state —
    /// so without this, reordering or bypassing would quietly revert whatever
    /// had been tweaked in a plugin's own window.
    private func add(_ descriptor: AudioUnitDescriptor) {
        engine.capturePluginStates(for: chain)
        settings.wrappedValue.processing.append(
            ProcessingItem(kind: .plugin(descriptor)))
    }

    private func remove(_ item: ProcessingItem) {
        engine.capturePluginStates(for: chain)
        settings.wrappedValue.processing.removeAll { $0.id == item.id }
    }

    private func move(_ item: ProcessingItem, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard target >= 0, target < items.count else { return }
        engine.capturePluginStates(for: chain)
        settings.wrappedValue.processing.swapAt(index, target)
    }

    @discardableResult
    private func move(_ dragged: UUID, before target: UUID) -> Bool {
        guard dragged != target,
              let from = items.firstIndex(where: { $0.id == dragged }),
              let to = items.firstIndex(where: { $0.id == target })
        else { return false }
        engine.capturePluginStates(for: chain)
        var updated = settings.wrappedValue.processing
        let moved = updated.remove(at: from)
        updated.insert(moved, at: to)
        settings.wrappedValue.processing = updated
        return true
    }
}
