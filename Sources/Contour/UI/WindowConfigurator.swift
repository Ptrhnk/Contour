import AppKit
import SwiftUI

/// Reaches the hosting `NSWindow` to raise it and optionally keep it above
/// other applications.
///
/// Contour is `LSUIElement`, so it has no Dock icon and does not appear in
/// ⌘-Tab. A window that falls behind something else is genuinely hard to get
/// back — the menu bar is the only route. Floating is therefore the sane
/// default here, with a pin control to turn it off.
struct WindowConfigurator: NSViewRepresentable {
    var isFloating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.isFloating = isFloating
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ConfiguringView else { return }
        view.isFloating = isFloating
        view.apply()
    }
}

private final class ConfiguringView: NSView {
    var isFloating = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        raise()
    }

    func apply() {
        guard let window else { return }
        window.level = isFloating ? .floating : .normal
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
