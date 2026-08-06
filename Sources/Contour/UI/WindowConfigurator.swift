import AppKit
import SwiftUI

/// Reaches the hosting `NSWindow` to raise it and optionally keep it above
/// other applications.
///
/// Contour is `LSUIElement`, so it has no Dock icon and does not appear in
/// ⌘-Tab: nothing else can bring this window back once it falls behind another
/// app. Rather than keeping it permanently above everything, the menu bar icon
/// raises it on demand — which is what this makes possible.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ConfiguringView: NSView {

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        raise()
    }

    func apply() {
        guard let window else { return }
        window.level = .normal
        // Follow to whichever Space is in front rather than dragging the user back.
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    /// `openWindow` alone does not bring an LSUIElement app forward.
    func raise() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
