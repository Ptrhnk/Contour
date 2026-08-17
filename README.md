# Contour

A macOS menu-bar utility that splits system audio into two independently
processed paths on one multi-channel interface: speakers on outputs 1/2,
headphones on outputs 3/4, each with its own EQ, AU plugin chain and output
gain.

Two reasons it exists. There is no free parametric EQ for system audio on
macOS, and the usual answer — leaving a DAW open to host an EQ and two plugins
— costs a gigabyte of RAM to use two percent of the application. And switching
between speakers and headphones is two actions, because you change the output
device *and* turn a volume knob; per-chain output gain, set once, removes the
knob.

Not a product. The repo is the distribution channel — clone it, build it, run it.

## Status

**v1.2.0**, everything the design set out for v1.

Two capture backends, switchable at runtime and level-matched to within 1 dB: a
muted global **process tap** (default, nothing to install) and **BlackHole 2ch**
loopback. Destination toggle (Speakers / Headphones / Both), per-chain trim and
gain, master bypass as a crossfade. 8-band parametric EQ per chain, in the
popover and in a resizable window. AU plugin hosting with a reorderable
processing list — the EQ is an item in it. Presets, AutoEq `ParametricEQ.txt`
import/export, undo/redo, peak-hold meters, launch at login with crash restart.

Not there yet: global hotkey, scroll-wheel-for-Q, 31-band mode, spectrum
analyser.

~1.7% of one core and 80 MB with no plugins; 250–400 MB with a room-correction
plugin per chain.

## Requirements

- macOS 14.4+ (the tap needs 14.2+, so it is always available)
- Xcode Command Line Tools (`xcode-select --install`); full Xcode not needed
- An audio interface. 4+ output channels gives both chains; a stereo-only device
  collapses to one and hides the destination switch.
- Optional: [BlackHole 2ch](https://existential.audio/blackhole/), for the
  second backend. Not bundled.

## Build

### 1. Signing certificate (once)

Not optional. macOS keys the microphone grant to bundle ID **plus signing
identity**, so without a stable identity every rebuild looks like a new app and
permission resets — or is silently denied.

In **Keychain Access** → *Certificate Assistant* → *Create a Certificate…*:
name **`Contour Dev`** (the Makefile looks for that name), *Self Signed Root*,
type **Code Signing**. Check it with
`security find-identity -v -p codesigning`. Another name works via
`make IDENTITY="Your Name"`.

### 2. Build

```sh
make run      # build, bundle, sign, launch
make verify   # signing authority, requirement, entitlements
swift test    # 40 DSP tests
```

`make verify`'s designated requirement must read
`designated => identifier "com.nahak.contour" and certificate leaf = H"…"` and
**not** a bare `cdhash H"…"` — a cdhash pins it to that one binary and resets
the microphone grant on every rebuild. Choose **Always Allow** when the first
`make sign` asks for the signing key.

Hosting third-party plugins under the hardened runtime needs
`com.apple.security.cs.disable-library-validation`, already in
`Contour.entitlements`.

## First run

1. **Grant microphone access when prompted.** Both backends read an audio
   *input* — the tap's or BlackHole's loopback — and macOS gates every input
   behind that grant. No microphone is recorded. Without it Core Audio returns
   silence and no error, so Contour refuses to start until it has it. There is
   no dock icon, so the prompt cannot come to the front: check other Spaces.
2. **Pick your interface** in the popover. Remembered after that.
3. On the tap that is all — leave the system output anywhere.

**BlackHole backend** (popover → Capture): set the system output to BlackHole
2ch, and leave its volume at **100%** — it has a software volume control that
attenuates digitally before Contour sees a sample, so level control belongs on
the interface. Contour warns and offers one-click fixes for both.

If the tap fails to start, Contour falls back to BlackHole and says why. The
fallback is not saved, so fixing the permission and relaunching returns to the
tap.

## Using it

- **Destination** — Speakers (1/2), Headphones (3/4), Both; the icon shows
  which. Right-click it for *Open EQ Editor* and *Quit*.
- **EQ** — drag a handle for freq/gain, ⌥-drag for Q, ⇧-drag for fine,
  double-click to enable/disable a band, right-click a band number to mute it.
  Type exact values into Freq / Gain / Q.
- **Bypass** — the chain header's power toggle or **B**. Crossfades to the dry
  capture; EQ and plugins keep rendering, so the A/B is instant both ways.
- **Match** — compensates the EQ's average level change, so switching it off
  does not also change loudness.
- **Auto trim** — trim at −(max boost) so the EQ cannot clip; can track edits.
  Make the level back up on the hardware knob.
- **Adapt. Q** — off by default: it reinterprets Q as gain changes, which would
  alter an imported AutoEq or EQ Eight curve.
- **Plugins** — `+` adds one; drag or use the arrows to reorder, including
  relative to the EQ; the dot bypasses; the slider button opens its editor.
  **Rescan** after installing a plugin — the component scan is cached.
- **Presets** — one shared library, chosen per chain; a whole chain each (EQ,
  trim, gain, processing list, plugin state). Number keys **1–9** in the open
  menu, `*` means unsaved. Plugin state is opaque binary, so presets only
  restore where the same plugins are installed; the shareable artefact is the
  curve alone, as AutoEq text.
- **Undo / redo** — ⌘Z, ⇧⌘Z in the EQ window.
- **At login** — one launchd agent that also restarts after a crash. Turn it off
  while working on the code, or `killall Contour` looks like a crash.

## If it doesn't work

Quit and relaunch; that is the correct level of support engineering here.

Plugins are hosted in-process deliberately, so a bad one can take Contour down
— loading is off the main thread with a 20 s timeout and the agent restarts the
process, which makes that an annoyance rather than an app that will not launch.

On BlackHole, Contour is the only thing draining the device: not running means
no sound. On the tap, audio returns to normal the moment the process dies.

```sh
log show --predicate 'subsystem == "com.nahak.contour"' --last 5m --style compact
```

## Licence

MIT — see [LICENSE](LICENSE). BlackHole is GPL-3.0, deliberately not bundled or
linked, only pointed at.
