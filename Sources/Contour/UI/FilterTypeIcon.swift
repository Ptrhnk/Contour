import ContourDSP
import SwiftUI

/// A small drawing of what each filter type does to the curve.
///
/// SF Symbols has nothing shaped like a filter response, and a word like
/// "High Shelf" needs far more width than the shape does. Drawing the response
/// is both narrower and more direct — the same reason Ableton uses glyphs here.
struct FilterTypeIcon: View {
    let type: EQBandType
    var size = CGSize(width: 20, height: 14)

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, canvasSize in
            let path = Self.path(for: type, in: canvasSize)
            context.stroke(path,
                           with: .color(.primary),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                              lineJoin: .round))
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel(type.title)
    }

    /// Drawn in view coordinates, so smaller y is higher gain.
    static func path(for type: EQBandType, in size: CGSize) -> Path {
        let width = size.width
        let inset: CGFloat = 1.5
        let mid = size.height / 2
        let high = inset
        let low = size.height - inset
        /// Sits between the flat band and the floor, used to keep a cut's far
        /// end steep instead of levelling off.
        let knee = mid + (low - mid) * 0.35

        var path = Path()
        switch type {
        case .bell:
            path.move(to: CGPoint(x: 0, y: mid))
            path.addLine(to: CGPoint(x: width * 0.22, y: mid))
            path.addCurve(to: CGPoint(x: width * 0.78, y: mid),
                          control1: CGPoint(x: width * 0.38, y: high),
                          control2: CGPoint(x: width * 0.62, y: high))
            path.addLine(to: CGPoint(x: width, y: mid))

        // Shelves fork: a shelf boosts or cuts, and drawing only the boost
        // hides half of what the control does.
        // Both plateaus are drawn as real horizontal runs, not curves stopping
        // at the edge: a shelf is a level change, so the levels have to be
        // visible. The fork shows that it goes either way.
        case .lowShelf:
            path.move(to: CGPoint(x: width, y: mid))
            path.addLine(to: CGPoint(x: width * 0.60, y: mid))
            path.addCurve(to: CGPoint(x: width * 0.34, y: high),
                          control1: CGPoint(x: width * 0.48, y: mid),
                          control2: CGPoint(x: width * 0.44, y: high))
            path.addLine(to: CGPoint(x: width * 0.05, y: high))

            path.move(to: CGPoint(x: width * 0.60, y: mid))
            path.addCurve(to: CGPoint(x: width * 0.34, y: low),
                          control1: CGPoint(x: width * 0.48, y: mid),
                          control2: CGPoint(x: width * 0.44, y: low))
            path.addLine(to: CGPoint(x: width * 0.05, y: low))

        case .highShelf:
            path.move(to: CGPoint(x: 0, y: mid))
            path.addLine(to: CGPoint(x: width * 0.40, y: mid))
            path.addCurve(to: CGPoint(x: width * 0.66, y: high),
                          control1: CGPoint(x: width * 0.52, y: mid),
                          control2: CGPoint(x: width * 0.56, y: high))
            path.addLine(to: CGPoint(x: width * 0.95, y: high))

            path.move(to: CGPoint(x: width * 0.40, y: mid))
            path.addCurve(to: CGPoint(x: width * 0.66, y: low),
                          control1: CGPoint(x: width * 0.52, y: mid),
                          control2: CGPoint(x: width * 0.56, y: low))
            path.addLine(to: CGPoint(x: width * 0.95, y: low))

        // A cut leaves the flat band through a soft knee and then runs away at
        // a constant slope — so the tangent is horizontal where it meets the
        // plateau and steep at the far end. Bending it the other way, sharp at
        // the corner and flattening at the floor, is what a cut does not do.
        // The knee sits nearer the middle than the edge, so the sloped section
        // — the part that says "cut" — gets most of the width instead of the
        // flat band taking it.
        // A straight slope ending on the floor, joined to the flat band by a
        // short knee. The slope has to finish on the bottom edge rather than
        // running off the side, or it reads as a shelf.
        case .lowCut:
            path.move(to: CGPoint(x: width * 0.16, y: low))
            path.addLine(to: CGPoint(x: width * 0.34, y: knee))
            path.addCurve(to: CGPoint(x: width * 0.66, y: mid),
                          control1: CGPoint(x: width * 0.46, y: mid + (knee - mid) * 0.45),
                          control2: CGPoint(x: width * 0.56, y: mid))
            path.addLine(to: CGPoint(x: width, y: mid))

        case .highCut:
            path.move(to: CGPoint(x: 0, y: mid))
            path.addLine(to: CGPoint(x: width * 0.34, y: mid))
            path.addCurve(to: CGPoint(x: width * 0.66, y: knee),
                          control1: CGPoint(x: width * 0.44, y: mid),
                          control2: CGPoint(x: width * 0.54, y: mid + (knee - mid) * 0.45))
            path.addLine(to: CGPoint(x: width * 0.84, y: low))

        case .notch:
            path.move(to: CGPoint(x: 0, y: mid))
            path.addLine(to: CGPoint(x: width * 0.4, y: mid))
            path.addLine(to: CGPoint(x: width * 0.5, y: low))
            path.addLine(to: CGPoint(x: width * 0.6, y: mid))
            path.addLine(to: CGPoint(x: width, y: mid))
        }
        return path
    }
}

/// The six types as shapes, three per row, replacing a dropdown that needed
/// 190 points to say "High Shelf".
struct FilterTypePicker: View {
    @Binding var type: EQBandType
    var iconSize = CGSize(width: 20, height: 14)

    /// Low end on the top row, high end below, so position carries meaning too.
    /// The two symmetric filters sit on opposite corners — bell top right, notch
    /// bottom left — and the two cuts on the other two, which reads better than
    /// grouping by kind down the columns.
    private var rows: [[EQBandType]] {
        [[.lowCut, .lowShelf, .bell], [.notch, .highShelf, .highCut]]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(row, id: \.self) { candidate in
                        button(candidate)
                    }
                }
            }
        }
    }

    private func button(_ candidate: EQBandType) -> some View {
        Button {
            type = candidate
        } label: {
            FilterTypeIcon(type: candidate, size: iconSize)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .background(candidate == type
                            ? Color.accentColor.opacity(0.3)
                            : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(candidate == type ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(candidate.title)
    }
}
