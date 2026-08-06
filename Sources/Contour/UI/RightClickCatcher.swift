import AppKit
import SwiftUI

/// Adds a right-click action to any view.
///
/// SwiftUI has no right-click gesture — only `contextMenu`, which costs a menu
/// and a second click for what should be one action. This overlays a view that
/// accepts *only* right and control clicks, passing everything else straight
/// through so the normal left-click behaviour is untouched.
struct RightClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> NSView {
        CatcherView(action: action)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.action = action
    }
}

private final class CatcherView: NSView {
    var action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Invisible to anything but a right or control click, so the view beneath
    /// keeps its ordinary click handling.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point)
        case .leftMouseDown, .leftMouseUp:
            // Written out rather than as `case .a, .b where ...`, where the
            // clause binds only to the last pattern — which made this swallow
            // every ordinary left click instead of passing it through.
            return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        action()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { action() } else { super.mouseDown(with: event) }
    }
}

extension View {
    /// Right-click (or control-click) to run `action`.
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}
