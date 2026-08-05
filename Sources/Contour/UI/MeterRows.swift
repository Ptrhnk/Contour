import SwiftUI

/// Meters live in their own leaf views on purpose.
///
/// `@Observable` invalidates whichever view *reads* a property. Reading
/// `engine.levels` inside `PopoverView` or `ChainSection` invalidates the whole
/// popover on every meter tick — which re-evaluates the EQ `Canvas`, the band
/// pickers and three `TextField(value:format:)` number formatters twenty times a
/// second, and costs ~30% of a core. Confining the read to these two small views
/// keeps the redraw to the meter itself.
struct InputMeterRow: View {
    var engine: AudioEngine

    var body: some View {
        let levels = engine.levels
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.db(max(levels.inputL, levels.inputR)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LevelMeter(left: levels.inputL, right: levels.inputR)
        }
    }
}

struct ChainMeterRow: View {
    var engine: AudioEngine
    let chain: Chain
    let isActive: Bool

    var body: some View {
        let levels = engine.levels
        LevelMeter(left: chain == .a ? levels.chainAL : levels.chainBL,
                   right: chain == .a ? levels.chainAR : levels.chainBR,
                   isActive: isActive)
    }
}
