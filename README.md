# TapEQ

A macOS menu bar app that applies parametric EQ to system audio, per output device and per app, using Core Audio process taps and a private aggregate device. It installs no audio driver, HAL plug-in or kernel extension, and it creates no audio device that other apps, Control Center or System Settings can see.

TapEQ picks presets automatically from rules. You can override its choice temporarily from the menu bar.

- **Preset**: a named EQ curve made of a preamp gain plus up to 12 bands.
- **Rule**: binds a preset to an output device, to an app, or to an app on one output device.
- **Override**: a temporary replacement for a rule, set from the menu bar and never saved.
- **Effective preset**: what a stream actually gets once overrides and rules are resolved.

## Requirements

- macOS 14.2 or later (the process tap API). Built and tested on macOS 27.2.
- Xcode 27 or later. The project uses the `project.xcproj` format that Xcode 27 introduced.
- Apple Silicon or Intel. Release builds are universal (`arm64` and `x86_64`).

## Build and run

Open `TapEQ.xcodeproj` in Xcode and run the **TapEQ** scheme, or from a terminal:

```sh
# Debug build
xcodebuild build -scheme TapEQ -destination 'platform=macOS' -derivedDataPath build/dd

# Release build (universal)
xcodebuild build -scheme TapEQ -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/dd

# Unit tests
xcodebuild test -scheme TapEQ -destination 'platform=macOS' -derivedDataPath build/dd

open build/dd/Build/Products/Debug/TapEQ.app
```

The project signs with the development team set in the project file (automatic signing, hardened runtime, no App Sandbox). To build without a team, add `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` to the command line. With an ad-hoc signature macOS treats every rebuild as a new app and asks for the audio permission again, so a real development identity is more comfortable.

There are no third-party dependencies.

## Permissions

TapEQ needs one permission: **System Audio Recording** (Privacy & Security › Screen & System Audio Recording › System Audio Recording Only). `Info.plist` carries `NSAudioCaptureUsageDescription`, and macOS asks the first time a tap starts.

macOS has no public API to ask whether this permission is granted. TapEQ infers it:

1. The first graph after launch is a **probe**: its taps do not mute anything and it plays nothing. Your audio is untouched.
2. As soon as a probe tap delivers a non-zero sample, capture evidently works. Only then does TapEQ build taps that mute.
3. If apps are playing but the probe hears only silence for three seconds, the menu bar menu and Settings say that capture is probably not allowed, with a button that opens the right pane. Nothing is muted in this state.

So a denied permission leaves all audio exactly as it was. After granting it in System Settings, quit and reopen TapEQ.

## Using it

**Menu bar menu.** A native menu. At the top, the current output with its effective preset, and a large Equalizer switch that turns all EQ off and back on with one click ("Bypass all EQ"). Below it, "Output Preset" and one item per playing app, each showing its effective preset and where it came from (App rule, Device rule, Same as output, Override). Each opens a submenu: "Follow Rules" (ticked when there is no override, and showing what the rules give) and the presets to override with. An override lasts until you choose Follow Rules, use "Clear All Overrides", or quit TapEQ. The icon gains a dot while an override is active and a slash while bypassed.

**Main window** ("Open TapEQ…"):

- **Presets**: built-in presets (read-only, can be duplicated) and your own. The editor has a response graph with draggable band handles (drag for frequency and gain, scroll or Option-drag for Q, double-click to add a band), a band table, a preamp slider, a headroom warning, and "Audition on current output", which applies the preset to the current output while the editor is open. Edits are heard immediately.
- **Output Devices**: every device seen so far, connected or not, each with a preset.
- **Apps**: app rules, optionally tied to one output device, with extra bundle IDs for helper processes.
- **Settings**: launch at login, Dock icon, the preset name next to the menu bar icon (on by default), permission status, the Bluetooth latency option, and engine diagnostics (taps, aggregate device, sample rate, buffer size, added delay, watchdog events, the last 100 log lines).

Data lives in `~/Library/Application Support/TapEQ/` as `presets.json`, `rules.json` and `settings.json`. Each write is atomic and the previous version of each file is kept as `<name>.bak`. A damaged file is replaced by its backup at launch, with a notice in the main window.

### Resolution order

For a process playing on the current default output device, the first match wins:

1. "Bypass all EQ" is on → None.
2. Override for the process's app.
3. Rule for the app on this device.
4. Rule for the app on any device.
5. Override for the device.
6. Rule for the device.
7. None.

A match whose preset is "None" still wins: it means "never equalize this". The whole order is one pure function, `Resolver.resolve`, in `TapEQ/Model/Resolver.swift`.

App rules match by bundle ID prefix at a dot boundary: a rule for `com.google.Chrome` covers `com.google.Chrome.helper`. A helper is also matched through the app it belongs to (its nearest ancestor process that is a regular app), which covers Electron apps whose helpers are named differently. When several rules match, the longest matching identifier wins.

## Architecture

```
TapEQ/
  DSP/      Band, Biquad (RBJ designs, magnitude response), EQCurve,
            EQKernel (real-time cascade, lock-free coefficient updates),
            SoftClipper, RTAtomics (C11 atomics for the audio thread)
  Engine/   CoreAudioSupport (HAL property wrappers), ProcessMonitor,
            DeviceMonitor, AppIdentity, RenderContext (the IOProc body),
            TapGraph (taps + aggregate + IOProc), AudioEngine
  Model/    Preset, Rule, Override, Resolver, Persistence, AppModel
  UI/       MenuBar/, MainWindow/, Shared/
TapEQTests/ DSP, resolver, persistence and model tests
```

### The audio graph

For the current default output device, `AudioEngine` resolves the effective preset of every audio process and builds one `TapGraph`:

- One `CATapDescription` per app-level preset: a private, stereo mixdown of the matching process objects, `mutedWhenTapped`.
- If the device has a preset, one private, stereo **global** tap that excludes TapEQ itself and every process an app-level decision already covers (including apps resolved to "None", which are therefore not tapped at all).
- One private aggregate device with the real output device as main sub-device and every tap in its tap list, drift compensation enabled.
- One IOProc, created with `AudioDeviceCreateIOProcIDWithBlock` and a nil queue so it runs on the device's IO thread. For each tap it runs that tap's EQ chain, sums the results, applies a soft clipper and writes the first two output channels (a mono device gets the average).

Processes with an app rule are placed in their tap even while they are idle. Starting or stopping playback then does not change the shape of the graph, so it costs no rebuild.

### How changes are applied

Every relevant event ends in `AudioEngine.reconcile()`, debounced to one run per 200 ms (the first event after a quiet spell is handled immediately):

| Change | What happens |
| --- | --- |
| A preset is edited | New coefficients are published to the running taps. No rebuild. |
| Processes join or leave a tap | The live tap's process list is edited in place (`kAudioTapPropertyDescription`). No rebuild. |
| The set of taps changes | A second graph is built in **standby** beside the running one: its taps read (and mute) but it plays nothing. Once its taps are delivering audio the two graphs cross-fade and the old one is destroyed. |
| Output device, sample rate or channel layout changes | Everything is torn down at once, then rebuilt for the new device. |
| Nothing playing needs EQ for 5 s | The graph is torn down, so the output device can idle. |

Teardown always runs in this order: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap` for every tap.

### Failing open

A `mutedWhenTapped` tap silences its processes while something reads it, so the engine is built around never leaving a tap muting without a graph that plays:

- A failed build destroys everything it created before the error is reported, then retries with back-off.
- A heartbeat checks four times a second that the IOProc is still being called. After 0.75 s without a call, all taps are destroyed and the graph is rebuilt.
- A device, format or default-output change, system sleep, and a restart of the audio server each tear everything down first.
- A standby graph is never left on its own: if the graph it was meant to relieve disappears, it is promoted or destroyed immediately.
- A watchdog rebuilds everything when a tap delivers only exact zeros for 3 s while one of its processes reports `IsRunningOutput`. It is limited to once per 30 s, and a tap that is still silent after a rebuild is left alone until it carries audio again (the process is simply playing silence).
- `SIGTERM`, `SIGINT` and `SIGHUP` are caught and tear down in order. After a force quit or crash the system destroys the taps and the aggregate itself: they are private and do not outlive the process.

### Real-time safety

`RenderContext.render` and `EQKernel.process` do not allocate, lock, log, dispatch or touch a class instance. All audio-side state is plain memory allocated before the IOProc starts and reached through unsafe pointers; the block the HAL calls captures a single raw pointer.

Coefficients are designed off the audio thread and handed over through two atomic cells per tap: `pending` (control → audio) and `retired` (audio → control, to be freed off the audio thread). Filter memory (z1/z2 per band per channel) lives on the audio side and survives a swap. A new coefficient set is reached by a 20 ms per-sample linear ramp of coefficients and preamp; the stable region of (a1, a2) is convex, so every point on the ramp is a stable filter. Graph start, stop and cross-over use an 8 ms fade.

The atomics are a header-only C module (`DSP/RTAtomics`), because Swift's own atomics need macOS 15. Use a Release build to judge real-time behaviour: unoptimized Swift is much slower and may call into the runtime.

### DSP notes

- Filters are RBJ Audio EQ Cookbook biquads in Direct Form II Transposed: peak, low shelf, high shelf, low-pass, high-pass.
- **Audio is 32-bit float end to end, but the filter recursion runs in double precision.** With 32-bit coefficients the required 0.1 dB accuracy cannot be met for low bands: a 30 Hz peak at 48 kHz is off by more than 0.1 dB, and a 20 Hz, Q 10 peak at 192 kHz by more than 10 dB, because a1 ≈ −2 and a2 ≈ 1 cannot hold the small difference that places the poles. `BiquadScalar` in `DSP/Biquad.swift` is the one-line switch back to `Float`.
- The soft clipper passes everything below 0.85 of full scale bit for bit and bends louder samples toward ±1.
- A flat preset is bit-transparent: identity bands are skipped and a preamp of 0 dB is not applied.

## Bluetooth latency

On a Bluetooth output the aggregate device delays tap audio by the latency the device reports (`kAudioDevicePropertyLatency`: 7,680 frames, 160 ms, on AirPods Max). That delay comes on top of the device's real latency, so equalized sound lags video by roughly 180 ms. It also means a freshly built tap delivers 160 ms of silence first. Wired, built-in and DisplayPort outputs showed no such delay.

Measured as the time from freezing a tone source to the tap going silent (this includes about 30 ms that is not tap delay):

| Output | Tap delay |
| --- | --- |
| MacBook Pro speakers | 34 ms |
| DisplayPort monitor | 29 ms |
| AirPods Max | 190 ms |
| AirPods Max with the trim | 29 ms |

Setting `kAudioSubTapExtraInputLatencyKey` to minus the reported latency cancels the delay and the start-up silence. **The value must not exceed what the system actually compensates: a value that is too large crashes `coreaudiod`**, which interrupts all audio on the Mac.

So the trim is **off by default**. Settings › "Reduce delay on Bluetooth outputs" turns it on, for Bluetooth outputs only. If a trimmed graph dies within 20 s of being built (audio server restart, stalled IOProc, watchdog, or the output vanishing), the trim is switched off for that device and stays off until you toggle the setting again.

Without the trim the engine still avoids gaps when the set of taps changes, through the standby cross-over described above. The one unavoidable gap is the very first graph after silence on a Bluetooth output, which starts with the tap's 160 ms lead-in.

## Known limitations

- **Apps that play to a device other than the system default output are out of scope.** TapEQ detects them (`kAudioProcessPropertyDevices`), leaves them untouched, and shows them as "Playing on another device". When the default output is itself an aggregate or multi-output device this detection is skipped.
- **Stereo only.** The first two channels of the output are written; other channels are silent while a graph is active. Surround content is mixed down to stereo by the taps.
- **WebKit audio is shared.** Safari and every other WebKit-based app play through `com.apple.WebKit.GPU`. A rule that matches it affects web audio in all of them. Adding Safari as an app pre-fills this identifier under "Also match".
- **The first moments of a stream are not equalized.** A graph is built when a process starts playing (about 100 ms), and after a launch the permission probe runs first (about 250 ms more, once).
- **Permission state is inferred**, as described under Permissions. An app that claims to be playing but emits digital silence can make the "probably not allowed" notice appear until real audio arrives.
- **Output devices that also have inputs** (USB headsets, for example) have not been tested on real hardware.
- **Graphs are built on the main thread**, which blocks the UI for about 100 ms per build.

## Tests

Unit tests cover the DSP (every band type against its analytical response within 0.1 dB, bit transparency of flat presets, click-free coefficient swaps), the resolution order, persistence and the app model. Run them with `xcodebuild test` as shown above.
