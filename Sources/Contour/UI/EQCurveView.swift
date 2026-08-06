import AppKit
import ContourDSP
import SwiftUI

/// Maps between the curve's pixel space and (frequency, dB).
struct EQGeometry {
    var size: CGSize
    var minimumFrequency = 20.0
    var maximumFrequency = 20_000.0
    /// A little wider than the ±15 dB band range so handles never sit on the edge.
    var displayDB = 18.0

    private var logMin: Double { log10(minimumFrequency) }
    private var logMax: Double { log10(maximumFrequency) }

    func x(frequency: Double) -> CGFloat {
        let clamped = min(max(frequency, minimumFrequency), maximumFrequency)
        return CGFloat((log10(clamped) - logMin) / (logMax - logMin)) * size.width
    }

    func frequency(x: CGFloat) -> Double {
        let t = Double(min(max(x, 0), size.width) / max(size.width, 1))
        return pow(10, logMin + t * (logMax - logMin))
    }

    func y(db: Double) -> CGFloat {
        let clamped = min(max(db, -displayDB), displayDB)
        return size.height * CGFloat(0.5 - clamped / (2 * displayDB))
    }

    func db(y: CGFloat) -> Double {
        let t = Double(min(max(y, 0), size.height) / max(size.height, 1))
        return (0.5 - t) * 2 * displayDB
    }
}

/// Holds the cached per-band curves so a drag only recomputes the band it moved.
///
/// Kept on the main actor deliberately: a full rebuild is 8 bands × 256 points
/// of biquad magnitude, a few tens of thousands of flops. The expensive thing in
/// this kind of view is the spectrum analyser behind the curve, and there isn't
/// one (§5.3).
@MainActor
@Observable
final class EQCurveModel {
    private let cache = EQCurveCache()
    private(set) var points: [Double] = []
    private(set) var sampleRate: Double = 44_100

    var frequencies: [Double] { cache.frequencies }
    var maximumBoostDB: Double { cache.maximumBoostDB }

    func rebuild(_ settings: EQSettings, sampleRate: Double) {
        self.sampleRate = sampleRate
        cache.rebuild(bands: settings.isEnabled ? settings.bands : [],
                      adaptiveQ: settings.adaptiveQ,
                      sampleRate: sampleRate)
        points = cache.composite
    }

    func update(bandAt index: Int, settings: EQSettings) {
        guard settings.isEnabled, index < settings.bands.count else {
            rebuild(settings, sampleRate: sampleRate)
            return
        }
        cache.update(bandAt: index, band: settings.bands[index], adaptiveQ: settings.adaptiveQ)
        points = cache.composite
    }
}

struct EQCurveView: View {
    @Binding var settings: EQSettings
    @Binding var selectedBand: Int
    var model: EQCurveModel
    var sampleRate: Double

    @State private var draggingBand: Int?
    /// The band's values and the cursor position when the drag began. Everything
    /// moves by an offset from these, so grabbing a handle off-centre does not
    /// snap it under the cursor.
    @State private var dragAnchor: (frequency: Double, gain: Double, q: Double,
                                    start: CGPoint)?

    /// Handles scale with the view so the large window is easier to hit.
    var handleRadius: CGFloat = 7.5

    var body: some View {
        GeometryReader { proxy in
            let geometry = EQGeometry(size: proxy.size)
            Canvas(rendersAsynchronously: false) { context, size in
                draw(&context, geometry: EQGeometry(size: size))
            }
            .contentShape(Rectangle())
            // A plain click only selects. Movement needs a deliberate drag, so
            // clicking a handle to inspect it cannot nudge the curve.
            .gesture(dragGesture(geometry))
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    if let band = nearestBand(to: value.location, geometry: geometry) {
                        selectedBand = band
                    }
                })
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    if let band = nearestBand(to: value.location, geometry: geometry) {
                        settings.bands[band].isEnabled.toggle()
                        selectedBand = band
                        model.update(bandAt: band, settings: settings)
                    }
                })
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { model.rebuild(settings, sampleRate: sampleRate) }
        .onChange(of: settings) { model.rebuild(settings, sampleRate: sampleRate) }
        .onChange(of: sampleRate) { model.rebuild(settings, sampleRate: sampleRate) }
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, geometry: EQGeometry) {
        drawGrid(&context, geometry: geometry)
        drawCurve(&context, geometry: geometry)
        drawHandles(&context, geometry: geometry)
    }

    private func drawGrid(_ context: inout GraphicsContext, geometry: EQGeometry) {
        let decades: [Double] = [50, 100, 500, 1_000, 5_000, 10_000]
        for frequency in decades {
            var path = Path()
            let x = geometry.x(frequency: frequency)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
            context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
        }
        for db in [-12.0, -6, 6, 12] {
            var path = Path()
            let y = geometry.y(db: db)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
            context.stroke(path, with: .color(.primary.opacity(0.07)), lineWidth: 1)
        }
        var zero = Path()
        let y = geometry.y(db: 0)
        zero.move(to: CGPoint(x: 0, y: y))
        zero.addLine(to: CGPoint(x: geometry.size.width, y: y))
        context.stroke(zero, with: .color(.primary.opacity(0.2)), lineWidth: 1)
    }

    private func drawCurve(_ context: inout GraphicsContext, geometry: EQGeometry) {
        let points = model.points
        let frequencies = model.frequencies
        guard points.count == frequencies.count, points.count > 1 else { return }

        var path = Path()
        for (index, db) in points.enumerated() {
            let point = CGPoint(x: geometry.x(frequency: frequencies[index]),
                                y: geometry.y(db: db))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        var fill = path
        fill.addLine(to: CGPoint(x: geometry.size.width, y: geometry.y(db: 0)))
        fill.addLine(to: CGPoint(x: 0, y: geometry.y(db: 0)))
        fill.closeSubpath()
        context.fill(fill, with: .color(.accentColor.opacity(0.15)))
        context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
    }

    private func drawHandles(_ context: inout GraphicsContext, geometry: EQGeometry) {
        for (index, band) in settings.bands.enumerated() {
            let isSelected = index == selectedBand
            // A disabled band contributes nothing to the curve, so its handle is
            // only clutter — unless it is the selected one, where a ghost is
            // what you aim at to bring it back.
            guard band.isEnabled || isSelected else { continue }

            let center = position(of: band, geometry: geometry)
            // One size, always. The selected handle used to swell by 20%, which
            // moved its edge under the pointer mid-drag.
            let circle = Path(ellipseIn: CGRect(x: center.x - handleRadius,
                                                y: center.y - handleRadius,
                                                width: handleRadius * 2,
                                                height: handleRadius * 2))
            context.fill(circle,
                         with: .color(band.isEnabled
                                      ? .accentColor.opacity(isSelected ? 1 : 0.75)
                                      : .secondary.opacity(0.3)))
            if isSelected {
                context.stroke(circle, with: .color(.primary.opacity(0.8)), lineWidth: 1.5)
            }
            context.draw(Text("\(index + 1)")
                            .font(.system(size: handleRadius * 1.2, weight: .bold))
                            .foregroundStyle(band.isEnabled ? Color.white : Color.secondary),
                         at: center)
        }
    }

    private func position(of band: EQBand, geometry: EQGeometry) -> CGPoint {
        CGPoint(x: geometry.x(frequency: band.frequency),
                y: geometry.y(db: band.type.usesGain ? band.gainDB : 0))
    }

    // MARK: - Interaction

    private func nearestBand(to location: CGPoint, geometry: EQGeometry) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, band) in settings.bands.enumerated() {
            // Only what is drawn can be grabbed. Hidden disabled bands would
            // otherwise still win the hit test and be dragged invisibly.
            guard band.isEnabled || index == selectedBand else { continue }
            let center = position(of: band, geometry: geometry)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best, best.distance < handleRadius * 3.5 else { return nil }
        return best.index
    }

    private func dragGesture(_ geometry: EQGeometry) -> some Gesture {
        // A few points of slop: below this it is a click, not a drag.
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let modifiers = NSEvent.modifierFlags
                if draggingBand == nil {
                    // Grab the nearest handle, or fall back to the selected one
                    // so a drag in empty space still does something predictable.
                    let band = nearestBand(to: value.startLocation, geometry: geometry)
                        ?? selectedBand
                    draggingBand = band
                    selectedBand = band
                    let current = settings.bands[band]
                    dragAnchor = (current.frequency, current.gainDB, current.q,
                                  value.startLocation)
                }
                guard let index = draggingBand, let anchor = dragAnchor,
                      index < settings.bands.count else { return }

                let fine = modifiers.contains(.shift) ? 0.25 : 1.0

                if modifiers.contains(.option) {
                    // ⌥-drag adjusts Q. Vertical distance is exponential so the
                    // whole range is reachable without a huge throw.
                    let delta = Double(anchor.start.y - value.location.y) / 40 * fine
                    let range = settings.bands[index].editableQRange
                    settings.bands[index].q =
                        min(max(anchor.q * pow(2, delta), range.lowerBound), range.upperBound)
                } else {
                    // Offset from where the drag began, not the cursor position,
                    // so the handle keeps its grab point.
                    let dx = (value.location.x - anchor.start.x) * fine
                    let anchorX = geometry.x(frequency: anchor.frequency)
                    settings.bands[index].frequency =
                        clampFrequency(geometry.frequency(x: anchorX + dx))

                    if settings.bands[index].type.usesGain {
                        let dy = (value.location.y - anchor.start.y) * fine
                        let anchorY = geometry.y(db: anchor.gain)
                        settings.bands[index].gainDB = clampGain(geometry.db(y: anchorY + dy))
                    }
                }
                model.update(bandAt: index, settings: settings)
            }
            .onEnded { _ in
                draggingBand = nil
                dragAnchor = nil
            }
    }

    private func clampFrequency(_ value: Double) -> Double {
        min(max(value, EQBand.frequencyRange.lowerBound), EQBand.frequencyRange.upperBound)
    }

    private func clampGain(_ value: Double) -> Double {
        min(max(value, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
    }
}
