# Contour

A macOS menu-bar utility that splits system audio into two independently
processed paths on a single multi-channel interface: speakers on outputs 1/2,
headphones on outputs 3/4, each with its own EQ and output gain.

It exists to solve one annoyance. Switching between speakers and headphones
normally means changing the system output device *and* turning a hardware volume
knob, because the two sit at different levels. Contour gives each path its own
output gain, set once, so switching is one click and no knob.

Not a product. The repo is the distribution channel — clone it, build it, run it.

## Status

Working: BlackHole backend, aggregate device, destination toggle
(Speakers / Headphones / Both), per-chain input trim and output gain, 8-band
parametric EQ per chain with a draggable curve, peak metering.

Not built yet: AU plugin hosting, presets, the process-tap backend, AutoEq text
import, global hotkey.

Costs about 1.7% of one core and 80 MB with no plugins loaded.

## Requirements

- macOS 14.4 or later
- Xcode Command Line Tools (`xcode-select --install`) — a full Xcode install is
  not required
- [BlackHole 2ch](https://existential.audio/blackhole/) — install it separately;
  it is not bundled
- An audio interface. Four or more output channels gives you both chains; a
  stereo-only device collapses to one chain and hides the destination switch.

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
swift test    # run the DSP tests
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

## First run

1. Set the system output device to **BlackHole 2ch**. Contour will offer a
   one-click fix if you forget.
2. **Grant microphone access when prompted.** Contour reads system audio back
   out of BlackHole, and macOS classifies reading any input device — including a
   virtual one — as microphone access. No microphone is recorded. Without the
   grant Core Audio returns silence with no error at all, so the app checks
   explicitly and tells you.
   Contour has no dock icon, so the prompt cannot come to the front; check other
   Spaces and behind windows if you don't see it.
3. **Leave BlackHole's volume at 100%.** It is one of the few devices with a
   software volume control, so the system slider attenuates in the digital
   domain before Contour sees a sample. Do level control on your interface.
   Contour warns and offers a reset if it drifts.

## Using it

- **Destination** — Speakers (out 1/2), Headphones (out 3/4), or Both. The menu
  bar icon shows which.
- **Gain** — per chain. Click the dB readout to reset to unity.
- **EQ** — drag a numbered handle for frequency and gain; ⌥-drag for Q; ⇧-drag
  for fine adjustment; double-click to enable or disable a band. Type exact
  values into the Freq / Gain / Q fields when transcribing a curve.
- **Auto trim** — sets input trim to −(maximum boost) so the EQ cannot clip.
  Digital attenuation before a modern DAC is free; make the level back up on the
  hardware knob.
- **Adapt. Q** — off by default, deliberately. It reinterprets Q as gain changes,
  which would silently alter an imported AutoEq or EQ Eight curve.

## If it doesn't work

Quit and relaunch. That genuinely is the correct level of support engineering
here.

If audio stops entirely: Contour is the only thing draining BlackHole, so if it
is not running, there is no sound. Check it is still alive.

For anything else, the log says what happened:

```sh
log show --predicate 'subsystem == "com.nahak.contour"' --last 5m --style compact
```

## Licence

MIT — see [LICENSE](LICENSE). BlackHole is GPL-3.0 and is deliberately not
bundled or linked, only pointed at.
