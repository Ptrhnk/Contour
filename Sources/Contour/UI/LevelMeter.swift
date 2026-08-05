import SwiftUI

/// Two-channel peak meter on a dB scale. Drawn in a single `Canvas` pass —
/// the whole point of metering here is that it costs less than the DSP.
struct LevelMeter: View {
    var left: Float
    var right: Float
    var isActive: Bool = true

    private let floor = Decibels.silenceFloor
    private let barHeight: CGFloat = 4
    private let spacing: CGFloat = 2

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(&context, size: size, level: left, row: 0)
            draw(&context, size: size, level: right, row: 1)
        }
        .frame(height: barHeight * 2 + spacing)
        .opacity(isActive ? 1 : 0.35)
        .accessibilityLabel("Level")
        .accessibilityValue(String(format: "%.0f decibels", max(left, right)))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, level: Float, row: Int) {
        let y = CGFloat(row) * (barHeight + spacing)
        let track = CGRect(x: 0, y: y, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: track, cornerRadius: barHeight / 2),
                     with: .color(.primary.opacity(0.08)))

        let fraction = CGFloat(max(0, min(1, (level - floor) / -floor)))
        guard fraction > 0 else { return }
        let filled = CGRect(x: 0, y: y, width: size.width * fraction, height: barHeight)
        context.fill(Path(roundedRect: filled, cornerRadius: barHeight / 2),
                     with: .color(color(for: level)))
    }

    private func color(for level: Float) -> Color {
        switch level {
        case ..<(-6): .green
        case ..<(-1): .yellow
        default: .red
        }
    }
}
