# Contour

macOS menu-bar utility. Splits system audio into two independently processed
paths on one multi-channel interface: speakers on outputs 1/2, headphones on
outputs 3/4, each with its own EQ and AU plugin chain. Menu bar toggle:
Speakers / Headphones / Both.

Solves one problem: switching between speakers and headphones currently means
changing the system output device *and* turning a hardware volume knob.
Per-chain output gain, set once, removes the knob.

Personal tool, source-only distribution. Not a product.

---

## Build

No Xcode project. SwiftPM builds the executable; the Makefile assembles and
signs the `.app`.

```
make build     # swift build only
make bundle    # assemble build/Contour.app
make sign      # codesign with identity "Contour Dev"
make run       # sign + relaunch
make verify    # print signing authority + embedded entitlements
make clean
```

Override with `make IDENTITY="..."` or `make CONFIG=debug`.

SwiftPM emits a bare Mach-O. SwiftUI needs a real bundle structure
(`Contents/MacOS`, `Contents/Info.plist`) — hence bundle assembly in the
Makefile. This is not a workaround to be replaced with an Xcode project.

---

## Settled decisions — do not relitigate

| Decision | Reason |
|---|---|
| Bundle ID `com.nahak.contour` is **permanent** | macOS keys the audio-capture TCC grant to bundle ID + signing identity. Changing either resets the grant. |
| Signing identity `Contour Dev`, self-signed, committed to the build | Same reason. Ad-hoc signing re-prompts for permission on every rebuild. Each person building the repo makes their own cert in Keychain Access. |
| `com.apple.security.cs.disable-library-validation: true` | Required to host third-party AU plugins under the hardened runtime. |
| `com.apple.security.device.audio-input: true` + `NSMicrophoneUsageDescription` | **Both** are mandatory, even for Backend B. See "Microphone TCC" below. |
| `app-sandbox: false` | Sandbox blocks the aggregate-device and tap work outright. |
| Menu-bar only — `LSUIElement: true`, `MenuBarExtra` + `.menuBarExtraStyle(.window)` | No dock icon, no main window. |
| **Do not use `AVAudioEngine`** | With the tap backend it silently fails: `kAudioOutputUnitProperty_CurrentDevice` returns `noErr` and the engine keeps reading the default input anyway. Use one `AudioDeviceCreateIOProcIDWithBlock` on the aggregate. |
| EQ built in-house, not `AUNBandEQ` | Its generic parameter-list UI cannot do grab-a-handle-and-drag, which is the point. ~200 lines of DSP costs less RAM too. |
| No cross-chain latency compensation | Comb filtering needs one listener hearing both chains. Two people on two headphone pairs each hear only their own. Dropped permanently, not deferred. |
| Inactive chains are torn down, not bypassed | Plugins deallocated, RAM returned. |
| Presets are a **single shared library**, not per chain | Departs from the spec. A pair of headphones arrives on chain B through the interface's 3/4 pair, or on chain A as a stereo-only Bluetooth device. Per-chain lists would hide a headphone curve from half the ways you can plug those headphones in. |
| Plugins referenced by *any preset of an active chain* stay instantiated but bypassed | Makes preset switching the click-free fast path. `Unload unused plugins` action exists for when RAM matters more. |
| Shelf Q is limited to 1/√2 in the UI, not in the design | Above it an RBJ shelf resonates: a "+6 dB" shelf at Q=18 swings +25/−19 dB. Correct filter behaviour, almost never wanted. Imports keep any Q they carry. |
| Launch at login and crash restart are one bundled LaunchAgent | `KeepAlive { SuccessfulExit = false }` gives both. Quitting from the menu stays quit. |
| No installer, notarization, DMG, auto-update, App Store | Repo is the distribution channel. |
| BlackHole stays unbundled | Link the official installer from the README. Also avoids interacting with its GPL-3.0. MIT for this repo. |

### Non-goals (v1)

Per-app processing. Output device picker. Spectrum analyser. 31-band graphic
mode. More than two chains. First-run wizard, onboarding, crash reporting,
analytics, preferences migration.

---

## Architecture

### Two input backends, one interface

```swift
protocol AudioSource {
    var format: AVAudioFormat { get }
    func start(_ render: @escaping RenderBlock) throws
    func stop()
}
```

Everything downstream — chains, EQ, plugins, routing — is identical either way.

```
Backend A:  apps → [muted tap] → Contour → interface ch 1/2 + 3/4
Backend B:  apps → BlackHole   → Contour → interface ch 1/2 + 3/4
```

**Backend B — BlackHole (build first).** System output set to BlackHole 2ch.
One private aggregate device: BlackHole 2ch as input sub-device with drift
compensation on; the interface as output sub-device *and* clock master
(`kAudioAggregateDeviceMainSubDeviceKey`); `kAudioAggregateDeviceIsPrivateKey:
true`.

**Backend A — process tap (preferred, build last).** `CATapDescription` with
`initStereoGlobalTapButExcludeProcesses([own PID])` — excluding our own PID is
mandatory or the render feeds back into itself — `muteBehavior = .muted`,
`privateTap = true`. Aggregate with the interface as main sub-device,
`kAudioAggregateDeviceTapListKey` referencing the tap UUID, and
`kAudioAggregateDeviceTapAutoStartKey: true`. Needs macOS 14.4+ and the TCC
grant.

Both end at the same place: one `AudioDeviceCreateIOProcIDWithBlock` on the
aggregate, 2 channels in, 4 out. One callback, one clock domain.

### Aggregate channel layout — measured, not assumed

Probed on an SSL 2+ (2 in / 4 out) + BlackHole 2ch, sub-device list
`[interface, capture]`:

```
full sub-device list order  = as supplied, interface first
input   4 ch, streams [2,2] → ch 0-1 SSL in,    ch 2-3 BlackHole   ← read here
output  6 ch, streams [4,2] → ch 0-3 SSL 1-4,   ch 4-5 BlackHole
```

Sub-devices are concatenated in list order, one `AudioBuffer` each, interleaved
within that buffer. `AggregateDevice.slot(logicalChannel:in:)` derives
(buffer, offset, stride) from the stream configuration — never hardcode indices,
the interface's own input count shifts the capture pair.

**The capture device's output channels are inside the aggregate**, and anything
written there loops straight back into its input. The IOProc silences *every*
output buffer before writing the destination pairs; do not "optimise" that
memset away.

Streams are verified 32-bit float at aggregate creation and creation fails
otherwise, so the render path can assume `Float`.

### Microphone TCC — the trap that cost an afternoon

Reading BlackHole is reading an **input device**, and macOS gates every input
device behind the microphone grant. This applies to Backend B, not just the tap.

Three separate things are all required, and each fails differently:

1. `NSMicrophoneUsageDescription` in `Info.plist`.
2. `com.apple.security.device.audio-input` in the entitlements. Under the
   hardened runtime, without it tccd logs
   `service: kTCCServiceMicrophone requires entitlement
   com.apple.security.device.audio-input but it is missing` →
   `Policy disallows prompt` → **denied without ever prompting**, and the
   process is killed with `SIGTRAP` when it asks.
3. The user actually granting it. Contour is `LSUIElement`, so the prompt
   cannot take focus and may sit behind another window.

**Without the grant, Core Audio returns silence and `noErr`.** No error, no
failed IOProc, correct callback rate, correct buffer layout, all zeros. If input
peaks read exactly 0.0 while a command-line process reading the same device sees
audio, it is this — not the channel map.

Do not call the completion-handler form of `AVCaptureDevice.requestAccess` from
`AudioEngine`. Swift infers the closure as `@MainActor` because the type is,
TCC invokes it on an XPC queue, and `swift_task_isCurrentExecutorWithFlags`
traps the process. Use the `async` form.

**Diagnosing anything on the audio path:** a command-line probe run with
`swift file.swift` inherits Terminal's TCC grants, so probe-versus-app is the
fastest way to separate a permissions problem from a Core Audio one. Probes that
read a loopback device must still zero their output buffers — one that doesn't
reads back its own stale buffer and reports sustained peaks above 1.0 that look
exactly like a real signal.

### Measuring CPU — `ps` lies here

`ps -o pcpu` reported 15–45% for a process that `sample` showed almost entirely
idle. It misaccounts CoreAudio's realtime IOThread. Measure consumed CPU time
over a wall-clock interval instead:

```sh
P=$(pgrep -f 'Contour.app/Contents/MacOS' | head -1)
ps -o time= -p $P   # sample twice, N seconds apart, take the delta
```

Real figure with the popover closed is ~1.7% of one core.

### SwiftUI redraw scope

`@Observable` invalidates whichever view *reads* a property. Reading
`engine.levels` from `PopoverView` invalidates the entire popover on every meter
tick, re-evaluating the EQ `Canvas`, the pickers and three
`TextField(value:format:)` number formatters. Meters therefore live in their own
leaf views (`MeterRows.swift`) — keep them there.

Meter polling runs at 50 ms while a UI is watching and 500 ms otherwise, decided
by `AudioEngine.meterViewCount`. That is a *count*, not a flag, because both the
popover and the EQ window show meters and either alone must raise the rate — a
single `isPopoverVisible` flag left the window's meters stepping along at two
updates per second whenever the popover was closed.

### Naming a chain after its device

With two output pairs, "Speakers" and "Headphones" are roles the user assigned to
outputs 1/2 and 3/4; Contour cannot see what is plugged into either, so it does
not guess. With a single stereo device the chain *is* that device, and it is
named accordingly — calling a pair of AirPods "Speakers" is simply wrong.

Classification comes from `kAudioStreamPropertyTerminalType`, which is a real
device property rather than a string match: AirPods report `'hdph'`, while USB
devices report the USB audio class numbers (0x0301 speaker, 0x0302 headphones).
Name matching survives only as a fallback for devices reporting `0`, and to pick
a model-specific icon, which terminal type cannot tell you.

### Testing

There is no Xcode on this machine, only Command Line Tools, so **XCTest is not
available**. Tests use swift-testing (`import Testing`, `@Test`, `#expect`),
which CLT does ship. `swift test` runs them.

### Startup gate — do not remove

A device's first buffers after starting can contain stale ring-buffer memory,
measured at magnitudes of **5 to 12 (+14 to +21 dBFS)**. Passed through to
headphones that is dangerous, not merely ugly.

It is **not deterministic** — it depends on what the device last held, so a
fixed-length mute is not reliably long enough. The gate instead holds the input
silent until it has read below +12 dBFS for three consecutive blocks (minimum
0.1 s), then fades in, with a 2 s hard timeout so a genuinely hot source still
plays. Applied to the input *before* the EQ, so those values cannot ring the
biquads either.

Runs on every start, which includes device changes and sample-rate rebuilds —
exactly when the burst was audible.

### The watchdog: why it is not `SMAppService`

Launch at login and crash restart are one launchd user agent written to
`~/Library/LaunchAgents` by `LaunchAgent.swift`. Three findings, each measured,
each of which broke an earlier attempt:

**`SMAppService` cannot work for a self-signed build.** launchd derives a
lightweight code requirement for a bundled agent and fails:

```
Service could not initialize: Unable to get updated LWCR for (…),
error 0x16 - Invalid argument
job state = spawn failed, last exit reason = OS_REASON_CODESIGNING
```

It retries every ten seconds forever. That machinery wants a trusted signature;
this project commits to a self-signed certificate with no Developer Program
(§8a). A plain agent predates LWCR and works — restart after `kill -9` measured
at about three seconds. Do not "modernise" this to `SMAppService`.

**A launchd label is single-use per login session.** Bootstrap a label, boot it
out, and it can never be bootstrapped again until logout: the command *reports
success* and the job silently never loads. `launchctl print` says the service
does not exist while Background Task Management still lists it as enabled.
`launchctl enable`, `launchctl kickstart`, and deleting and rewriting the plist
all fail to recover it.

So labels are **generational** — `com.nahak.contour.watchdog.N`. Each install
claims a fresh one and retires the previous. The happy path (job still loaded,
executable path unchanged) does nothing at all, because reinstalling means
booting out first, which is the one action that destroys the label.

**launchd bypasses LaunchServices.** It execs the binary directly, so opening
the app from Finder while the watchdog's copy runs starts a *second* instance —
two engines building two aggregate devices over the same hardware.
`applicationWillFinishLaunching` exits duplicates with status 0, so `KeepAlive`
treats it as a clean exit rather than a crash to recover from.

While the watchdog is enabled, `killall Contour` looks like a crash and the app
returns in ~3 s, which races `make run`. Turn it off while iterating.

### AppKit will terminate this app if you let it

Adding a `Window` scene made AppKit treat Contour as a windowed app, so with no
window open macOS terminated it as idle — logged only as
`_kLSApplicationWouldBeTerminatedByTALKey=1`, no crash report, nothing in our
own log. For this app that means **all audio stops**, since nothing else drains
BlackHole.

Held off by `NSSupportsAutomaticTermination=false` and
`NSSupportsSuddenTermination=false` in `Info.plist`,
`applicationShouldTerminateAfterLastWindowClosed → false`, and
`disableAutomaticTermination` at launch. Do not remove any of them.

### Shelf Q, and why the control stops at 1/√2

Measured, high shelf at 8 kHz asking for **+6 dB**:

```
   Q  | sweep max  sweep min
 0.71 |      6.0        0.0     ← monotonic
 1.00 |      6.4       -0.4
 2.00 |      8.9       -2.9
18.00 |     25.1      -19.1
```

`alpha = sin(ω₀)/(2Q)` is the RBJ cookbook shelf, and Q = 1/√2 is exactly where
his slope parameter S = 1 — steepest without overshoot. Ableton feels gentler
because EQ Eight reparameterises shelves by slope and never exposes this region.

`EQBandType.editableQRange` narrows the *control* for shelves only.
`EQBand.editableQRange` widens it again when a band already carries a higher Q,
so an AutoEq or Equalizer APO curve keeps its exact value. The design itself
still accepts the full range — AutoEq targets Equalizer APO, whose `LSC`/`HSC`
are these same RBJ shelves with this same Q convention, so changing the
parameterisation would silently mistranslate every imported curve.

### Swift traps that produced audible bugs

**`didSet` runs during `init`.** A property with a default value — including
any `Optional`, which is implicitly `nil` — is already initialised when the
`init` body runs, so assigning the persisted value there *is* a re-assignment
and fires the observer. Restoring settings therefore scheduled a restart before
the engine had started: the app started twice and faded in twice. `AudioEngine`
guards every observer with `isLoading`, cleared at the end of `init`.

**A `Picker`'s binding writes back on first layout.** That is not a user
choice. `interfaceUID` restarts only when the *resolved* device changes.

### Core Audio property listeners match the address exactly

`kAudioDevicePropertyNominalSampleRate` is **global scope**. Registering it
against `kAudioObjectPropertyScopeOutput` silently never fires — measured:

```
global-scope listener fired: 1x   output-scope listener fired: 0x
```

This is not cosmetic. EQ coefficients are computed for a specific sample rate,
so an undetected rate change detunes every band. A drift backstop in the meter
poll compares the aggregate's actual rate against the engine's and rebuilds if
they diverge, in case a notification is ever missed again.

### Chain activity on a stereo-only device

`isChainActive(_:)` is the single source of truth, read by both the audio thread
and the UI. On a stereo device chain A is always active whatever the destination
says — otherwise a destination of Headphones left over from a four-output
interface silences the app completely, and the destination picker is hidden on
such devices so there is no way back.

### Realtime rules

Inside the IOProc: no allocation, no locks, no ARC traffic on new objects, no
logging. Pre-allocate every buffer at setup. Parameter changes cross from the
UI thread via a triple buffer published with an atomic index.

The IOProc reaches its state through `Unmanaged...toOpaque()` captured in the
block, deinterleaves the capture pair into planar scratch, calls one stored
`RenderBlock` closure, then interleaves the chain outputs back. Known caveat:
calling a stored Swift closure emits lock-free retain/release — no allocation
and no lock, so not a realtime hazard, but when the real chain object lands in
step 3 replace `RenderBlock` with a `(context, @convention(c) fn)` pair so the
render path is genuinely zero-ARC.

Planar scratch is 8192 frames per channel, allocated once. Callbacks larger than
that output silence rather than overrun; nothing on macOS asks for more.

### Signal flow, per chain

```
input → input trim → [ordered processing list] → output gain → channel pair
```

The processing list holds the built-in EQ and any AU plugins as reorderable
items — drag the EQ above or below a plugin. Replaces any pre/post-EQ
distinction.

### EQ engine

Eight parametric bands, modelled on Ableton's EQ Eight.

- Types: Low/High Shelf, Bell, Low/High Cut, Notch. Freq 20 Hz–20 kHz
  (log-scaled), Gain ±15 dB, Q 0.1–18, per-band enable.
- Default layout: bands 1–2 shelf/cut, 3–6 bells, 7–8 shelf/cut.
- Disabled bands are **excluded from the cascade**, not run at unity.
- Cascade of biquads via `vDSP_biquadmD` — double precision, both channels in
  one call. ~0.3% of one core.
- RBJ cookbook coefficients in `Double`, **with Orfanidis correction above
  ~0.25 × sample rate**. Not academic: a narrow high-Q notch at 10–12 kHz comes
  out shifted and wrong under the plain bilinear transform at 44.1 kHz.
- Never swap coefficients discontinuously — ramp with
  `vDSP_biquadm_SetTargetsDouble` over ~20 ms.
- Optional adaptive Q: Q rises with |gain| so small moves stay broad.
- Recompute on sample-rate change.

**Curve display:** cache each band's magnitude on a fixed ~256-point
log-frequency grid in dB; the composite is their sum because dB adds. Dragging
band 4 recomputes only band 4, then one `vDSP_vadd`. SwiftUI `Canvas`, 30 fps
cap while dragging, idle otherwise, computed on a background actor — never on
the audio thread. No spectrum analyser (it is the single most expensive thing
in Ableton's window).

**Interaction:** drag handle = freq/gain; scroll or ⌥-drag = Q; click the
number = select band; double-click = toggle enabled; ⇧-drag = fine. Numeric
entry for Freq/Gain/Q on the selected band.

**Clipping:** one-click "set input trim to −(max boost)", computed from the
cached composite response.

**Text presets:** AutoEq `ParametricEQ.txt` import/export. Types `PK`, `LSC`,
`HSC`, `LP`, `HP`, `NO`. Unknown types warn, do not fail the import. Paste and
drag-and-drop.

### AU hosting

- Enumerate with `AVAudioUnitComponentManager`, effects only. **Cache it** —
  the scan is slow.
- `AUAudioUnit.instantiate(with:options:)` **in-process** — out-of-process
  isolation adds IPC jitter a realtime insert cannot absorb.
- `allocateRenderResources()` and `maximumFramesToRender` off the realtime
  thread, before starting.
- Render via each unit's `renderBlock` into pre-allocated buffer lists.
- Plugin UI via `requestViewController`, in a separate `NSWindow` so the
  popover can close independently.
- Persist `fullStateForDocument` per plugin.
- Sum each unit's `latency`, display the per-chain total.

### Presets

A preset is a full snapshot of **one chain**: EQ bands, input trim, output
gain, the ordered processing list, each plugin's `fullStateForDocument`, every
enabled flag. Per-chain, so headphone presets are independent of speaker
presets.

Switching must not click, gap, or stall the audio thread:

- **Same plugin set** (the common case) — instantiate nothing. Push new
  parameters through the existing triple buffer, ramp bypass over ~20 ms.
- **Different plugin set** — instantiate and `allocateRenderResources()` on a
  background thread, build the complete new chain, swap one atomic pointer in
  the render block. Release the old chain on the background thread afterwards.

JSON in Application Support. Plugin state is opaque binary, so presets only
restore on a machine with the same plugins — personal configuration, not
shareable. The **shareable** artefact is the EQ curve alone as AutoEq
`ParametricEQ.txt`. Two separate concepts; keep them separate in the UI.

Per-chain preset menu, number-key hotkeys for the first slots, explicit
"unsaved changes" indicator.

### UI

`MenuBarExtra`, `.menuBarExtraStyle(.window)`, `SMAppService.mainApp.register()`
for launch at login. Popover top to bottom: destination segmented control
(Speakers / Headphones / Both); a tab per chain with preset menu, EQ curve,
processing list, output gain; footer with backend switch (Tap / BlackHole),
latency readout, master bypass. Menu bar icon shows the active destination.
Global hotkey for destination switching from day one.

Device adaptation: read the device's channel count. 4+ outputs → both chains
and a channel-pair dropdown. Stereo-only → one chain, hide the destination
switch.

---

## Edge cases

| Event | Handling |
|---|---|
| System output isn't BlackHole | Detect on launch and on change. Clear prompt with a one-click fix; never silently process nothing. |
| System volume not 100% on BlackHole backend | BlackHole exposes a software volume control, so the slider digitally attenuates before Contour sees the audio. Detect non-unity and warn. |
| Interface unplugged | Stop cleanly, error state, poll for return. |
| Sample rate change | Rebuild aggregate, recompute coefficients, reallocate plugin resources. |
| Sleep / wake | Tear down before sleep, rebuild after. |
| Contour not running, BlackHole backend | Silence — nothing drains the virtual device. Mitigate with launch-at-login + crash-restart watchdog. |
| Contour not running, tap backend | Audio returns to normal; the mute dies with the process. **Verify explicitly** — a stuck system-wide mute is the worst possible failure. Tear the tap down on `SIGTERM`. |
| Tap permission revoked | Detect on IOProc failure, deep-link to the Settings pane, fall back to BlackHole. |
| Microphone permission missing or revoked | Checked explicitly before starting, because Core Audio reports silence rather than an error. Popover offers the prompt, or deep-links to Privacy & Security once the answer is no longer `notDetermined`. |
| Plugin crashes | Takes the process down. The watchdog is not optional. |

---

## Build order

1. **BlackHole backend + passthrough.** Aggregate device, 4 channels out, dry
   to both pairs. Confirm stable across sleep/wake and sample-rate change.
2. **Chain routing.** Destination toggle, per-chain output gain. *At this point
   it already solves the original problem — ship steps 1–2 to yourself before
   starting 3.*
3. **8-band parametric EQ** on chain B — DSP first, then the curve view.
4. **Menu bar UI.**
5. **AU hosting**, both chains.
6. **Presets**, per chain, including the atomic chain swap.
7. **Tap backend**, same `AudioSource` interface, switchable at runtime — which
   also gives an honest level-matched A/B against BlackHole. The only step with
   genuine unknowns.
8. Text preset import/export, watchdog, channel-pair assignment, polish.

**Current state: v0.8.0 on `au-hosting` — build-order steps 1–6 done. Step 7
(the process-tap backend) not started.** `main` sits at v0.6.0, the EQ-only
release.

Not 1.0 yet, deliberately: the spec's v1 includes the tap backend, and plugin
hosting has only just stopped freezing. Version 1 wants step 7 done and the
plugin path to have survived real use.

Version lives in `Resources/Info.plist` as `CFBundleShortVersionString` and is
shown beside the name in the popover. Tagged releases mark states worth
returning to; `v0.6.0` is the EQ-only app, complete and in daily use.

Working: private aggregate build/teardown, verified channel mapping, one IOProc
doing dry passthrough into both output pairs, microphone TCC handling,
device/sample-rate/sleep-wake listeners with coalesced restart, interface
auto-pick persisted in `UserDefaults` under `interfaceUID`, per-channel input
peak metering, popover showing status + warnings for "system output isn't
BlackHole" and "BlackHole volume below unity" with one-click fixes. Measured
66 MB RSS, 0.3% CPU at 44.1 kHz, verified end to end with signal on the meters.

Diagnostics: `log show --predicate 'subsystem == "com.nahak.contour"' --last 30s
--style compact`. Meter lines are `.notice` on purpose — `.debug` is not
persisted by default, and an absent `.debug` line looks identical to a dead
callback.

Also working: destination toggle (Speakers / Headphones / Both), per-chain
output gain and input trim, 8-band parametric EQ per chain with draggable curve
and Freq/Gain/Q knobs, presets (shared library, per-chain selection), peak-hold
meters with a never-falling maximum, a large resizable EQ window, launch at
login with crash restart, and device-aware chain naming.

Also on `au-hosting`: AU plugin hosting with a reorderable processing list,
AutoEq text import and export, undo/redo, loudness-matched EQ bypass.

Not there yet: the tap backend, a global hotkey, scroll-wheel-for-Q, 31-band
mode, spectrum analyser.

Measured with the popover closed: **1.7% of one core**, ~80 MB RSS.

Sleep/wake is wired but has never been exercised. Sample-rate change has been
verified live.

Source layout:

```
Sources/CContourAtomics/          one atomic integer for the triple buffer
Sources/ContourDSP/               pure DSP, no UI, no Core Audio — unit tested
  BiquadCoefficients.swift        normalised section + magnitude response
  EQBand.swift                    band model, defaults, EQSettings
  EQDesign.swift                  Orfanidis peaking + RBJ cookbook
  EQCurve.swift                   cached per-band dB grid, composite via vDSP
  EQKernel.swift                  vDSP_biquadmD cascade, ramped targets
Sources/Contour/
  ContourApp.swift                @main + AppDelegate (starts/stops the engine)
  Model/Chain.swift               Destination, ChainParameters, ChainSettings
  UI/PopoverView.swift            popover shell, per-chain tabs
  UI/EQCurveView.swift            curve canvas + drag/⌥/⇧/double-click
  UI/EQSection.swift              band editor, numeric entry, auto-trim
  UI/LevelMeter.swift, MeterRows.swift
  Audio/CoreAudioProperties.swift throwing AudioObject property wrapper
  Audio/AudioDevices.swift        enumeration, default output, volume
  Audio/AggregateDevice.swift     aggregate lifecycle + channel mapping
  Audio/AudioSource.swift         AudioSource protocol, RenderBuffers
  Audio/BlackHoleSource.swift     Backend B + the IOProc
  Audio/PropertyListener.swift    scoped property listener
  Audio/TripleBuffer.swift        UI → realtime parameter handoff
  Audio/ChainEQ.swift             coefficient publisher + per-chain cascade
  Audio/AudioEngine.swift         orchestration, status, restart policy
Tests/ContourDSPTests/            swift-testing (XCTest is unavailable, below)
```

Run the tests with `swift test`. 23 tests, all passing.

---

## Performance expectation

| | RAM |
|---|---|
| Contour, no plugins | < 60 MB |
| SoundID Reference | +150–250 MB |
| CanOpener | +30–60 MB |
| Realistic both-chains total | 250–400 MB |

CPU: 8 stereo biquads is under 0.5% of one core. The curve view costs more than
the DSP. Plugins dominate both.
