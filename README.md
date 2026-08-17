# Contour

A macOS menu-bar utility that splits system audio into two independently
processed paths on a single multi-channel interface: speakers on outputs 1/2,
headphones on outputs 3/4, each with its own EQ, AU plugin chain and output
gain.

It exists for two reasons.

**There is no free parametric EQ for system audio on macOS.** The usual way to
get one is to leave a DAW running in the background purely to host an EQ and a
couple of plugins — which works, but costs a gigabyte of RAM and a launch every
time you sit down, to use perhaps two percent of the application. Contour is
the EQ and the plugin chain without the DAW around them.

**Switching between speakers and headphones is two actions, not one.** You
change the system output device *and* turn a hardware volume knob, because the
two sit at different levels. Contour gives each path its own output gain, set
once, so switching is one click and no knob.

Not a product. The repo is the distribution channel — clone it, build it, run it.

## Status

**v1.2.0.** Everything the design set out for v1 is in.

- Two capture backends, switchable at runtime: a **muted global process tap**
  (default, macOS 14.2+, nothing to install) and **BlackHole 2ch** loopback.
  Both are level-matched to within a deliberate 1 dB of headroom.
- Destination toggle (Speakers / Headphones / Both), per-chain input trim and
  output gain, master bypass as a crossfade.
- 8-band parametric EQ per chain, draggable curve, in the popover and in a
  large resizable window.
- **AU plugin hosting** with a reorderable processing list — drag the EQ above
  or below a plugin — per-plugin bypass, plugin editor windows, and per-chain
  latency readout.
- Presets: full snapshots of a chain including plugin state, one shared library,
  selected per chain.
- AutoEq `ParametricEQ.txt` import and export, undo/redo, peak-hold metering,
  launch at login with crash restart.

Not there yet: a global hotkey, scroll-wheel-for-Q, 31-band graphic mode,
spectrum analyser.

Costs about 1.7% of one core and 80 MB with no plugins loaded. Plugins dominate
both — expect 250–400 MB with a room-correction plugin on each chain.

## Requirements

- macOS 14.4 or later. The tap backend needs 14.2+, so on any supported system
  it is available; **BlackHole is optional** and only needed if you want to A/B
  the two capture paths or the tap is unavailable to you.
- Xcode Command Line Tools (`xcode-select --install`) — a full Xcode install is
  not required
- An audio interface. Four or more output channels gives you both chains; a
  stereo-only device collapses to one chain and hides the destination switch.
- Optional: [BlackHole 2ch](https://existential.audio/blackhole/), installed
  separately. Not bundled.

## Build

### 1. Create a signing certificate (once, five minutes)

This step is not optional and skipping it will waste your time later. macOS keys
the microphone permission grant to the bundle identifier **plus the signing
identity**. Without a stable identity, every rebuild looks like a different app
and macOS asks for permission again — or silently denies it.

In **Keychain Access**:

1. Menu → *Certificate Assistant* → *Create a Certificate…*
2. Name: **`Contour Dev`** (the Makefile looks for this exact name)
3. Identity Type: *Self Signed Root*
4. Certificate Type: **Code Signing**
5. Create.

Verify it exists:

```sh
security find-identity -v -p codesigning
```

Use a different name if you like, then build with `make IDENTITY="Your Name"`.

### 2. Build and run

```sh
make run      # build, bundle, sign, launch
make verify   # print the signing authority, requirement and entitlements
swift test    # run the DSP tests (40 of them)
```

`make verify`'s designated requirement must **not** be a bare `cdhash H"…"`. It
should read:

```
designated => identifier "com.nahak.contour" and certificate leaf = H"…"
```

A bare cdhash means the requirement is pinned to that exact binary, and your
microphone grant will reset on every rebuild. The Makefile pins it to the
certificate to prevent this.

The first `make sign` will ask permission to use the signing key. Choose
**Always Allow**, or it asks again on every build.

Hosting third-party plugins under the hardened runtime needs
`com.apple.security.cs.disable-library-validation`, which is already in
`Contour.entitlements`.

## First run

1. **Grant microphone access when prompted.** Both backends read an audio
   *input* stream — the tap's, or BlackHole's loopback — and macOS gates every
   input device behind the microphone grant. No microphone is recorded. Without
   the grant Core Audio returns silence with no error at all, so Contour checks
   explicitly and refuses to start until it has it.
   Contour has no dock icon, so the prompt cannot come to the front; check other
   Spaces and behind windows if you don't see it.
2. **Pick your interface** in the popover's Interface row. Contour picks a
   candidate on first launch and remembers the choice.
3. That's it on the tap backend — leave the system output wherever you like, it
   captures whatever is playing. Contour will point out if the system output is
   still BlackHole, since the volume keys act on that device.

### If you use the BlackHole backend instead

Switch it in the popover's **Capture** row, then:

1. Set the system output device to **BlackHole 2ch**. Contour offers a one-click
   fix if you forget.
2. **Leave BlackHole's volume at 100%.** It is one of the few devices with a
   software volume control, so the system slider attenuates in the digital
   domain before Contour sees a sample. Do level control on your interface.
   Contour warns and offers a reset if it drifts.

If the tap fails to start — permission never granted, or revoked — Contour falls
back to BlackHole automatically and says why. The fallback is not saved, so
fixing the permission and relaunching puts you back on the tap.

## Using it

- **Destination** — Speakers (out 1/2), Headphones (out 3/4), or Both. The menu
  bar icon shows which. Right-click the icon for *Open EQ Editor* and *Quit*.
- **Gain / Trim** — per chain. Click the dB readout to reset to unity.
- **EQ** — drag a numbered handle for frequency and gain; ⌥-drag for Q; ⇧-drag
  for fine adjustment; double-click a handle to enable or disable a band;
  right-click a band number to mute it. Type exact values into the Freq / Gain /
  Q fields when transcribing a curve.
- **Master bypass** — the power toggle on the chain header, or the **B** key.
  It crossfades to the dry capture over one buffer; the EQ and plugins keep
  rendering behind it, so the A/B is instant in both directions.
- **Match** — compensates the EQ's average level change, so switching the EQ off
  does not also change loudness.
- **Auto trim** — sets input trim to −(maximum boost) so the EQ cannot clip, and
  can keep it there as you edit. Digital attenuation before a modern DAC is
  free; make the level back up on the hardware knob.
- **Adapt. Q** — off by default, deliberately. It reinterprets Q as gain changes,
  which would silently alter an imported AutoEq or EQ Eight curve.
- **Plugins** — `+` in the Processing list adds an effect; drag or use the
  arrows to reorder, including relative to the EQ; the power dot bypasses one;
  the slider button opens its editor window. **Rescan** after installing a
  plugin, because the component scan is cached.
- **Presets** — one shared library, selected per chain. A preset is a whole
  chain: EQ, trim, gain, the processing list and each plugin's state. Number
  keys **1–9** load the first nine from the open menu. `*` means unsaved
  changes. Plugin state is opaque binary, so presets only restore on a machine
  with the same plugins — the shareable artefact is the EQ curve alone, as
  AutoEq `ParametricEQ.txt`.
- **Undo / redo** — ⌘Z and ⇧⌘Z in the EQ window.
- **At login** — one launchd agent that also restarts Contour if it crashes.
  Turn it off while iterating on the code, or `killall Contour` looks like a
  crash and it comes straight back.

## If it doesn't work

Quit and relaunch. That genuinely is the correct level of support engineering
here.

A plugin is hosted in-process, deliberately, so a badly behaved one can take
Contour down with it. Loading is off the main thread with a 20 s timeout, and
the login agent restarts the process, which together mean a bad plugin is a
recoverable annoyance rather than an app that will not start.

On the BlackHole backend, Contour is the only thing draining the virtual device
— if it is not running there is no sound at all. On the tap backend, audio
returns to normal the moment the process dies; the mute cannot outlive it.

For anything else, the log says what happened:

```sh
log show --predicate 'subsystem == "com.nahak.contour"' --last 5m --style compact
```

## Licence

MIT — see [LICENSE](LICENSE). BlackHole is GPL-3.0 and is deliberately not
bundled or linked, only pointed at.
