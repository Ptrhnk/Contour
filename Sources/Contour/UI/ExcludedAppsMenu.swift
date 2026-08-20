import SwiftUI

/// Picks the apps the tap leaves alone.
///
/// The app list is built inside the menu's content closure rather than in
/// `body`, because assembling it walks the HAL's process table and asks
/// LaunchServices for names — work worth doing when the menu is opened and not
/// on every redraw of the popover.
struct ExcludedAppsMenu: View {

    @Bindable var engine: AudioEngine

    var body: some View {
        Menu {
            let apps = engine.excludableApps
            if apps.isEmpty {
                Text("No apps are playing")
            }
            ForEach(apps) { app in
                Toggle(isOn: Binding(
                    get: { engine.excludedAppBundleIDs.contains(app.bundleID) },
                    set: { engine.setExcluded($0, bundleID: app.bundleID) })) {
                    Text(app.isPresent ? app.name : "\(app.name) — not running")
                }
            }
        } label: {
            Text(engine.excludedSummary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("""
            Apps listed here are left out of the capture entirely. Their audio is \
            neither processed nor muted — it reaches the interface by its own route, \
            which is what a DAW applying its own room calibration needs.

            An excluded app plays to whatever device and output pair it is set to, \
            so Contour's Speakers / Headphones switch does not move it.
            """)
    }
}
