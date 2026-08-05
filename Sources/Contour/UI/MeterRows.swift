import SwiftUI

/// Meters live in their own leaf views on purpose.
///
/// `@Observable` invalidates whichever view *reads* a property. Reading
/// `engine.levels` inside `PopoverView` or `ChainSection` invalidates the whole
/// popover on every meter tick — which re-evaluates the EQ `Canvas`, the band
/// pickers and three `TextField(value:format:)` number formatters twenty times a
/// second. Confining the read to these two small views keeps the redraw to the
/// meter itself.
struct InputMeterRow: View {
    var engine: AudioEngine

    var body: some View {
        let meter = engine.levels.input
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Spacer()
                MaximumReadout(meter: meter) { engine.resetMaximum(.input) }
            }
            LevelMeter(left: meter.left, right: meter.right)
        }
    }
}

struct ChainMeterRow: View {
    var engine: AudioEngine
    let chain: Chain
    let isActive: Bool

    var body: some View {
        let meter = engine.levels[chain]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Output").font(.caption).foregroundStyle(.secondary)
                Spacer()
                MaximumReadout(meter: meter) { engine.resetMaximum(.chain(chain)) }
            }
            LevelMeter(left: meter.left, right: meter.right, isActive: isActive)
        }
    }
}

/// The never-falling peak. Clicking it clears that meter, which is the only way
/// to answer "does it still clip?" after changing something.
private struct MaximumReadout: View {
    let meter: StereoMeter
    let reset: () -> Void

    var body: some View {
        Button(action: reset) {
            Text(Format.db(meter.maximum))
                .font(.caption.monospacedDigit())
                .foregroundStyle(meter.didClip ? Color.red : .secondary)
        }
        .buttonStyle(.plain)
        .help(meter.didClip
              ? "Peak reached full scale. Click to reset."
              : "Maximum since reset. Click to reset.")
    }
}
