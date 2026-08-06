import AppKit
import ContourDSP
import SwiftUI

/// Import and export the curve as AutoEq `ParametricEQ.txt`.
///
/// Shared by both editors rather than duplicated: the format is the one
/// artefact that transfers between machines, and two copies of the parsing
/// entry points would eventually disagree about what importing does to the trim.
struct AutoEqTransferButton: View {
    @Binding var settings: ChainSettings
    var onMessage: (String) -> Void

    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 1) {
                // Nudged up: the glyph's tray sits at its base, so its optical
                // centre is below its geometric one.
                Image(systemName: "square.and.arrow.down")
                    .offset(y: -1)
                // Says "this opens something" rather than "this does something".
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Import or export the curve as AutoEq ParametricEQ.txt. "
              + "You can also drop a file or text onto the curve.")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                item("Paste AutoEq Text") { importFromClipboard() }
                item("Open AutoEq File…") { importFromFile() }
                Divider()
                item("Copy as AutoEq Text") { exportToClipboard() }
                item("Save AutoEq File…") { exportToFile() }
            }
            .padding(10)
            .frame(width: 180)
        }
    }

    private func item(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            showing = false
            action()
        } label: {
            Text(title)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transfer

    private func apply(_ text: String) {
        onMessage(AutoEqTransfer.apply(text, to: &settings))
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            onMessage("The clipboard has no text.")
            return
        }
        apply(text)
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        apply(text)
    }

    private var exportText: String {
        AutoEqPreset.export(bands: settings.eq.bands, preampDB: Double(settings.inputTrimDB))
    }

    private func exportToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText, forType: .string)
        onMessage("Copied the curve as AutoEq text.")
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ParametricEQ.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportText.write(to: url, atomically: true, encoding: .utf8)
            onMessage("Saved.")
        } catch {
            onMessage(error.localizedDescription)
        }
    }
}


/// The import itself, separate from the control that offers it, so a drop target
/// can reuse it without building a view to call a method on.
enum AutoEqTransfer {

    /// Also sets the trim from the file's preamp and switches auto-trim off:
    /// the file states its own and the two would fight. Returns what to tell
    /// the user.
    @discardableResult
    static func apply(_ text: String, to settings: inout ChainSettings) -> String {
        do {
            let imported = try AutoEqPreset.parse(text)
            settings.eq.bands = AutoEqPreset.bands(from: imported)
            settings.eq.isEnabled = true
            settings.autoTrim = false
            settings.inputTrimDB = Float(min(max(imported.preampDB,
                                                 Double(ChainSettings.trimRange.lowerBound)), 0))
            guard imported.warnings.isEmpty else {
                return imported.warnings.joined(separator: " ")
            }
            return "Imported \(imported.bands.count) filters, preamp "
                + String(format: "%.1f dB.", imported.preampDB)
        } catch {
            return error.localizedDescription
        }
    }
}
