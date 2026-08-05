import SwiftUI

/// Two-channel peak meter on a dB scale, drawn in a single `Canvas` pass.
///
/// The filled bar is the falling level; the tick is the short-term peak hold,
/// which is what makes a transient visible at all on a bar that decays.
struct LevelMeter: View {
    var left: ChannelMeter
    var right: ChannelMeter
    var isActive: Bool = true

    private let floor = Decibels.silenceFloor
    private let barHeight: CGFloat = 5
    private let spacing: CGFloat = 2

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(&context, size: size, meter: left, row: 0)
            draw(&context, size: size, meter: right, row: 1)
        }
        .frame(height: barHeight * 2 + spacing)
        .opacity(isActive ? 1 : 0.35)
        .accessibilityLabel("Level")
        .accessibilityValue(String(format: "%.0f decibels", max(left.level, right.level)))
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - floor) / -floor)))
    }

    private func draw(_ context: inout GraphicsContext,
                      size: CGSize,
                      meter: ChannelMeter,
                      row: Int) {
        let y = CGFloat(row) * (barHeight + spacing)
        let track = CGRect(x: 0, y: y, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: track, cornerRadius: barHeight / 2),
                     with: .color(.primary.opacity(0.08)))

        let level = fraction(meter.level)
        if level > 0 {
            let filled = CGRect(x: 0, y: y, width: size.width * level, height: barHeight)
            context.fill(Path(roundedRect: filled, cornerRadius: barHeight / 2),
                         with: .color(color(for: meter.level)))
        }

        let hold = fraction(meter.hold)
        if hold > 0 {
            let x = min(size.width * hold, size.width - 1.5)
            let tick = CGRect(x: x, y: y, width: 1.5, height: barHeight)
            context.fill(Path(tick), with: .color(color(for: meter.hold).opacity(0.9)))
        }
    }

    private func color(for level: Float) -> Color {
        switch level {
        case ..<(-6): .green
        case ..<(-1): .yellow
        default: .red
        }
    }
}
