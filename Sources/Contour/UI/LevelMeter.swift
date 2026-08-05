import SwiftUI

/// Two-channel peak meter, drawn in a single `Canvas` pass.
///
/// The scale runs to **+6 dBFS**, not 0. Everything upstream is 32-bit float,
/// where 0 dBFS is just the value 1.0 and not a ceiling — real material with
/// intersample overs sits above it routinely. Stopping the bar at 0 would pin
/// it at full width and throw away exactly the information worth seeing. The
/// 0 dB line is marked so "how far over" is readable at a glance.
struct LevelMeter: View {
    var left: ChannelMeter
    var right: ChannelMeter
    var isActive: Bool = true

    private let floor = Decibels.silenceFloor
    private let ceiling: Float = 6
    private let barHeight: CGFloat = 5
    private let spacing: CGFloat = 2

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(&context, size: size, meter: left, row: 0)
            draw(&context, size: size, meter: right, row: 1)
            drawUnityMark(&context, size: size)
        }
        .frame(height: barHeight * 2 + spacing)
        .opacity(isActive ? 1 : 0.35)
        .accessibilityLabel("Level")
        .accessibilityValue(String(format: "%.0f decibels", max(left.level, right.level)))
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - floor) / (ceiling - floor))))
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

    /// 0 dBFS: below it nothing can clip, above it the float→integer conversion
    /// into the interface will.
    private func drawUnityMark(_ context: inout GraphicsContext, size: CGSize) {
        let x = size.width * fraction(0)
        var path = Path()
        path.move(to: CGPoint(x: x, y: -1))
        path.addLine(to: CGPoint(x: x, y: barHeight * 2 + spacing + 1))
        context.stroke(path, with: .color(.primary.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
    }

    private func color(for level: Float) -> Color {
        switch level {
        case ..<(-6): .green
        case ..<0: .yellow
        default: .red
        }
    }
}
