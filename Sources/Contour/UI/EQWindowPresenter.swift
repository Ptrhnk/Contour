import AppKit
import SwiftUI

/// Opens the EQ window from anywhere, including AppKit.
///
/// `openWindow` is an environment value, so it can only be read inside a SwiftUI
/// view — and the status item's context menu is a plain `NSMenu`. The menu bar
/// label is the one view guaranteed to exist from launch whether or not the
/// popover is ever opened, so it registers the action here on appearance.
@MainActor
final class EQWindowPresenter {

    static let shared = EQWindowPresenter()

    private var openWindow: ((String) -> Void)?

    func register(_ action: @escaping (String) -> Void) {
        openWindow = action
    }

    /// Opens the editor, or raises it if it is already open and buried.
    ///
    /// This is the alternative to keeping the window permanently on top: the
    /// menu bar icon is how you find it again, so it does not have to sit above
    /// everything else the rest of the time.
    func show() {
        // The popover is key while it is open; dismiss it so the window is not
        // opening behind a panel that is about to vanish anyway.
        let popover = NSApp.keyWindow
        if popover?.title != EQWindowView.windowTitle {
            popover?.orderOut(nil)
        }

        openWindow?(EQWindowView.id)

        // The scene may only exist after this runloop turn, and an LSUIElement
        // app does not come forward on its own.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            guard let window = NSApp.windows.first(where: {
                $0.title == EQWindowView.windowTitle
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// The menu bar icon. A view rather than a bare `Image` so it can reach
/// `openWindow` and hand it to `EQWindowPresenter` — see there for why.
struct MenuBarLabel: View {

    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear {
                EQWindowPresenter.shared.register { openWindow(id: $0) }
            }
    }
}
