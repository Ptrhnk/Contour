import SwiftUI

/// One colour per band, as FabFilter Pro-Q draws them, or the single accent
/// colour Contour has always used.
///
/// A display preference rather than part of a chain or preset, kept in
/// `UserDefaults` so one switch covers the popover and the window at once.
enum BandColors {
    static let storageKey = "colorBands"

    private static let palette: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple,
    ]

    static func color(_ index: Int) -> Color { palette[index % palette.count] }

    /// Background of a numbered band selector.
    static func selectorFill(_ index: Int, isEnabled: Bool, isSelected: Bool,
                             colored: Bool) -> Color {
        if colored, isEnabled { return color(index).opacity(isSelected ? 0.45 : 0.18) }
        return isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)
    }
}

/// The switch itself, placed beside Adapt. Q in both editors.
struct BandColorToggle: View {
    @AppStorage(BandColors.storageKey) private var colored = false

    var body: some View {
        Toggle(isOn: $colored) {
            Image(systemName: "paintpalette")
        }
        .toggleStyle(.button)
        .help(colored ? "One colour per band — click for a single colour"
                      : "Single colour — click to colour each band separately")
    }
}
