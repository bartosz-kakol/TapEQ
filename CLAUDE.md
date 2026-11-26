# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TapEQ is a macOS menu bar app (Swift, SwiftUI, Core Audio C APIs) that applies parametric EQ to system audio per output device and per app. It uses Core Audio process taps and a private aggregate device: no driver, no HAL plug-in, no device visible to other apps. `README.md` has the design and the Bluetooth latency measurements; read it before changing the engine.

Hard constraints from the project owner: public APIs only, no drivers, no third-party dependencies (tests may use one only if necessary), no code copied from GPL projects, minimum macOS 14.2, universal binary, hardened runtime, no App Sandbox.

Use the project's terms in code and UI: **Preset**, **Rule**, **Override**, **Effective preset**.

## Commands

```sh
# Build (Debug)
xcodebuild build -scheme TapEQ -destination 'platform=macOS' -derivedDataPath build/dd

# Build (Release, universal)
xcodebuild build -scheme TapEQ -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/dd

# All tests
xcodebuild test -scheme TapEQ -destination 'platform=macOS' -derivedDataPath build/dd

# One test class or one test
xcodebuild test -scheme TapEQ -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:TapEQTests/ResolverTests
xcodebuild test -scheme TapEQ -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:TapEQTests/ResolverTests/testStep1BypassBeatsEverything

# Only the lines that matter from a build
... 2>&1 | grep -E "error|warning:|BUILD" | grep -v appintents
```

The build must stay free of warnings in project code. The `appintentsmetadataprocessor` warning is Xcode's own and is expected. There is no linter.

`build/` is ignored by git. The first test run in a session can take a few minutes while the host app launches.

## The Xcode project

The project uses Xcode 27's `project.xcproj` format (a JSON-like file), not `project.pbxproj`. There is no XcodeGen `project.yml`; the file is edited by hand and the owner keeps the project open in Xcode, so do not regenerate or replace it.

- Source folders are synchronized: a file added under `TapEQ/` or `TapEQTests/` joins its target automatically. Adding a source file needs no project edit.
- After editing the project file, validate and normalize it with `/Applications/Xcode.app/Contents/Developer/usr/bin/xcprojformatter --update TapEQ.xcodeproj`. It rejects malformed input with a message that names the problem.
- `TapEQ/Info.plist` is a partial plist merged with the generated one (`GENERATE_INFOPLIST_FILE`). It exists because `NSAudioCaptureUsageDescription` has no `INFOPLIST_KEY_` build setting. It is excluded from the target's resources through `membership-exceptions`; a new file that must not be bundled needs the same treatment.
- `SWIFT_INCLUDE_PATHS` points at `TapEQ/DSP/RTAtomics`, a header-only C module (`import RTAtomics`). Both targets need it.
- Tests are hosted by the app (`TEST_HOST`/`BUNDLE_LOADER`) and use `@testable import TapEQ`.

## Swift conventions that are easy to get wrong

- Swift 5 language mode, default isolation is `nonisolated` (the template's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` was removed on purpose). UI, model, engine and monitor classes are marked `@MainActor` explicitly; DSP and the render path are deliberately not.
- HAL listeners are registered on the main queue and hop with `MainActor.assumeIsolated`. Timers and `asyncAfter` closures do the same.
- Deployment target is 14.2: no `Synchronization.Atomic` (macOS 15), no `AudioHardwareSystem` Swift wrappers (macOS 15), no `CATapDescription.bundleIDs` without an availability check (macOS 26).
- When the app hosts unit tests (`AppEnvironment.isRunningTests`) it must stay inert: no engine start, no activation policy change, and `PersistentStore.standard` resolves to a temporary folder. Keep new launch-time behaviour behind that guard.

## Architecture

```
UI (SwiftUI)  ──reads/edits──▶  AppModel  ──EngineConfiguration──▶  AudioEngine
                                   │                                    │
                              PersistentStore                 ProcessMonitor, DeviceMonitor
                                                                        │
                                                                    TapGraph ──▶ RenderContext / EQKernel (IO thread)
```

**Model (`TapEQ/Model`)**. `AppModel` (`@Observable`) owns presets, rules, known devices, overrides and settings. Every mutation saves (debounced) and calls `pushConfiguration()`, which hands the engine a value snapshot: `ResolutionContext` plus presets. Overrides and the audition are in memory only; the audition is injected as a device override at push time. `Resolver.resolve` is the single, pure implementation of the resolution order (bypass → app override → app-on-device rule → app rule → device override → device rule → none); a match whose preset is nil ("None") still wins. Rules that point at a deleted preset are skipped, not removed.

**Engine (`TapEQ/Engine`)**. `AudioEngine.reconcile()` is the one place where state becomes audio. It computes a `GraphPlan` (one `TapPlan` per app-level preset, plus one global tap if the device has a preset) and compares it with what is running:

- equal plan: nothing;
- same shape, different process lists: `TapGraph.updateScope` edits the live tap in place;
- different shape: a second `TapGraph` is built in `.standby` next to the running one and they cross-fade once its taps carry audio;
- no graph yet: built `.audible`;
- capture permission not yet proven: built `.probe` (taps do not mute, nothing is played). There is no public API for the permission, so it counts as granted once a tap delivers a non-zero sample.

A `TapGraph` is immutable in shape: taps + private aggregate device + one IOProc. Teardown order is fixed: stop → destroy IOProc → destroy aggregate → destroy taps.

Processes with an app-level rule are in their tap even while idle, and are excluded from the global tap, so starting playback does not change the plan. A process playing to a non-default device is excluded everywhere.

**Fail open is the governing rule.** `mutedWhenTapped` taps silence their processes while read, so no tap may be left muting without a graph that plays. Any new failure path must destroy taps first and rebuild afterwards (`tearDownAll`). The heartbeat, watchdog, device/format callbacks, sleep notification and audio-server-restart handler all follow this. A standby graph must never outlive the graph it is replacing.

**DSP (`TapEQ/DSP`)**. RBJ biquads, Direct Form II Transposed. Audio is Float32 end to end but coefficients and filter state are `BiquadScalar` (Double): Float coefficients cannot meet the 0.1 dB accuracy requirement for low bands, and a test pins this. Coefficient sets are published through two atomic cells (`pending`, `retired`) and reached by a per-sample ramp.

**UI (`TapEQ/UI`)**. There is no SwiftUI scene: `TapEQApp` is an AppKit `@main` that runs `NSApplication` with `AppDelegate`. The menu bar item is an `NSStatusItem` with a native `NSMenu` (`StatusMenuController`), rebuilt from a `MenuState` value when the menu opens and while it is open; only its header (`StatusMenuHeader`: output, effective preset, the EQ on/off tile) is SwiftUI in an `NSHostingView`. Overrides are set from per-target submenus ("Follow Rules" + presets) and always use `.untilCleared`. The main window is an `NSWindow` hosting `MainWindowView`, owned by `MainWindowController`, because a SwiftUI `Window` scene cannot be kept closed at launch on macOS 14. The app is `LSUIElement`; `AppDelegate` installs a main menu by hand so ⌘Q, ⌘W and text editing shortcuts work.

Artwork is the owner's: `TapEQ/AppIcon.icon` (Icon Composer; matched by `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`) and the `MenuBarGlyph` template SVG in the asset catalog. `MenuBarIcon` draws the override dot and the bypass slash on top of the glyph in code; do not redraw or restyle the artwork itself.

## Real-time code

`RenderContext.render` and everything in `EQKernel` that it calls run on the device's IO thread. In that code: no allocation, locks, logging, dispatch, class instances, arrays, closures or existentials. State is plain memory allocated up front in `RenderMemory` / `EQKernel.create` and reached through unsafe pointers; cross-thread communication goes through the `tapeq_atomic_*` cells only. Use `while` loops over indices, as the existing code does. Judge real-time behaviour in a Release build.

## Hazards when running against live audio

This app changes what the user hears, and experiments happen on the user's own machine.

- **Never pass a tap `latency-in` more negative than the system's compensation.** A value that is too large crashes `coreaudiod` and interrupts all audio on the Mac. This is why the Bluetooth latency trim (`GraphPlan.latencyTrimFrames`) is opt-in, Bluetooth-only and guarded by a circuit breaker. Do not experiment with other values on the user's machine without asking. During development −60 frames on the built-in speakers, −88 on a DisplayPort monitor and −7,700 on AirPods Max each crashed the audio server; −7,680 (the latency AirPods Max report) is fine. See "Bluetooth latency" in the README.
- Check `/Library/Logs/DiagnosticReports/` for new `coreaudiod-*.ips` files after any engine experiment.
- Stop only the instance you started, by PID. The owner often has their own instance running from Xcode; a `pkill -f TapEQ` kills that too.
- Do not change the system's default output device or reset the app's privacy permission to test something. Ask, or use the hooks below.
- Launch through LaunchServices (`open`), not by running the binary, so the app rather than the terminal owns the audio capture permission.

### Development hooks

```sh
open -n --env TAPEQ_DATA_DIR=/path/to/dir --env TAPEQ_LOG_FILE=/path/to/log \
  build/dd/Build/Products/Debug/TapEQ.app
```

| Variable | Effect |
| --- | --- |
| `TAPEQ_DATA_DIR` | Use this folder instead of `~/Library/Application Support/TapEQ/`. Always set it for experiments, so the user's real rules are untouched. |
| `TAPEQ_LOG_FILE` | Engine log plus one line of levels per second. This is how to verify the engine without the UI. |
| `TAPEQ_TRACE` | Adds a line per tick with each tap's silence counters. |
| `TAPEQ_OUTPUT_DEVICE_UID` | Debug only: treat this device as the output instead of the system default. |
| `TAPEQ_OPEN_SECTION` | Debug only: open the main window on `presets`, `devices`, `apps` or `settings`. |
| `TAPEQ_SNAPSHOT_DIR` | Debug only: render screens to PNG and quit. Offscreen rendering does not draw the sidebar or scroll views; for a faithful picture open a section and use `screencapture -l <window id>`. |

A process without a bundle ID is matched as `exec:<name>` (for example a rule for `exec:afplay`), which makes command-line players usable as test sources without touching the user's own apps.

## Status

Nothing has been committed beyond the initial scaffold commit; do not commit unless asked. Several acceptance checks need a person at the machine. "Measured" below means checked through the engine's level meters and logs on real audio, not by ear.

| Check | State |
| --- | --- |
| An app rule changes only that app's sound; no device appears in Control Center or Audio MIDI Setup | Measured with stand-in sources (`exec:afplay`); output level matched the preset. Not checked by ear, with Spotify/Safari, or in Control Center. |
| A device rule follows output switches with no manual action | Not run (needs switching the Mac's output). |
| App rule beats device rule; app override beats both; "Bypass all" removes every tap | Rule vs. rule and bypass measured. App override: unit tests only. |
| Opening a mic on AirPods (profile switch) recovers audio within about 1 s | Not run. |
| Force-quitting restores normal audio | Partly: after `kill -9` the system had destroyed the old tap. Not checked by ear. |
| Denying the capture permission leaves audio untouched and shows a message | Not run (permission already granted on the build machine). |
| Duplex outputs (USB headsets): taps map to the last input buffers | Confirmed on a virtual duplex device (layout `[1, 2]`), not on real hardware. |
