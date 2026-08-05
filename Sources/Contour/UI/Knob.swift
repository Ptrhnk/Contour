import AppKit
import SwiftUI

/// A rotary control. Vertical drag adjusts; ⇧ makes it fine; double-click
/// returns to the default.
///
/// Frequency and Q are logarithmic because a linear 20 Hz–20 kHz sweep spends
/// nine tenths of its travel above 2 kHz, which makes the bottom of the range
/// unusable.
struct Knob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    var defaultValue: Double?
    var diameter: CGFloat = 34

    /// Points of vertical travel for the full range.
    private let travel: Double = 130
    /// Gap at the bottom of the dial, so the ends of the range are distinguishable.
    private let sweep = Angle.degrees(270)

    @State private var anchor: Double?

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(&context, size: size)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(drag)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if let defaultValue { value = clamp(defaultValue) }
            })
        .accessibilityLabel(title)
        .help("\(title): drag to adjust, ⇧-drag for fine"
              + (defaultValue != nil ? ", double-click to reset" : ""))
    }

    // MARK: - Value mapping

    private var normalized: Double {
        guard logarithmic else {
            return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        }
        let low = log10(max(range.lowerBound, 1e-6))
        let high = log10(range.upperBound)
        return (log10(max(value, 1e-6)) - low) / (high - low)
    }

    private func value(fromNormalized t: Double) -> Double {
        let t = min(max(t, 0), 1)
        guard logarithmic else {
            return range.lowerBound + t * (range.upperBound - range.lowerBound)
        }
        let low = log10(max(range.lowerBound, 1e-6))
        let high = log10(range.upperBound)
        return pow(10, low + t * (high - low))
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Interaction

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if anchor == nil { anchor = normalized }
                guard let anchor else { return }
                let fine = NSEvent.modifierFlags.contains(.shift)
                let delta = Double(-gesture.translation.height) / travel * (fine ? 0.2 : 1)
                value = clamp(value(fromNormalized: anchor + delta))
            }
            .onEnded { _ in anchor = nil }
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 3
        let start = Angle.degrees(135)
        let end = start + sweep

        var track = Path()
        track.addArc(center: centre, radius: radius, startAngle: start,
                     endAngle: end, clockwise: false)
        context.stroke(track, with: .color(.primary.opacity(0.15)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))

        let t = min(max(normalized, 0), 1)
        if t > 0.001 {
            var fill = Path()
            fill.addArc(center: centre, radius: radius, startAngle: start,
                        endAngle: start + sweep * t, clockwise: false)
            context.stroke(fill, with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        let angle = start + sweep * t
        let inner = radius - 6
        var pointer = Path()
        pointer.move(to: CGPoint(x: centre.x + cos(angle.radians) * inner * 0.35,
                                 y: centre.y + sin(angle.radians) * inner * 0.35))
        pointer.addLine(to: CGPoint(x: centre.x + cos(angle.radians) * inner,
                                    y: centre.y + sin(angle.radians) * inner))
        context.stroke(pointer, with: .color(.primary.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
