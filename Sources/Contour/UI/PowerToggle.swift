import SwiftUI

/// On/off for a thing that processes audio — a band, the EQ, a plugin.
///
/// Deliberately distinct from a checkbox. Checkboxes are settings; this is a
/// signal path being switched in or out, and it appears in enough places that
/// it is worth being the same control every time.
struct PowerToggle: View {
    @Binding var isOn: Bool
    var diameter: CGFloat = 18

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: "power")
                .font(.system(size: diameter * 0.6, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .background(isOn ? Color.accentColor : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: diameter * 0.25))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
