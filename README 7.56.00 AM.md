<p align="center">
  <img src="doc/logo.png" alt="spank logo" width="200">
</p>

# spank

Slap your MacBook, it yells back.

`spank` is a macOS utility for Apple Silicon MacBooks that watches the built-in motion sensor, detects chassis impacts, and plays back voice or sound effects in response. The current codebase is a native Swift and Objective-C runtime: the live stack is split into a daemon, a sensor helper, and a control client, with strict media validation and per-user launchd deployment.

This codebase is intended as the mainline modern implementation. It is currently best treated as an alpha/testing release.

## Origin And Credit

This project started from [taigrr/spank](https://github.com/taigrr/spank), which popularized the “slap your MacBook, it yells back” idea and shipped the original implementation.

The sensor path itself traces back further to [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer), the Python implementation by `olvvier` that documented and exposed the Apple Silicon laptop IMU path through IOKit HID. That work is the more important technical precursor here: it identified and operationalized the undocumented `AppleSPUHIDDevice` / SPU sensor route that made projects like `spank` possible in the first place.

This repository keeps that lineage explicit:

- original product/project inspiration: [taigrr/spank](https://github.com/taigrr/spank)
- original Python IMU implementation and SPU/HID discovery work: `olvvier` / [apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)

## What This Version Is

This version is not the old single-root, single-binary utility.

It has been refactored into a native-heavy runtime with:

- `spankd`: the main daemon
- `spank-sensor-helper`: the narrow sensor relay
- `badapple`: the local control client
- `bruiseberry/`: the internal Apple-platform toolkit namespace that now holds the Swift and Objective-C runtime implementation

The installed runtime path is native, and this repository now ships only that native implementation.

## Requirements

- macOS on an Apple Silicon MacBook with the internal motion sensor path available
- a logged-in GUI session for the default LaunchAgent deployment model
- Xcode Command Line Tools

Notes:

- this project depends on an undocumented Apple sensor path and may break on future macOS or hardware revisions
- this is laptop-specific behavior; it is not a general motion framework for all Apple hardware

## How It Works

At runtime, the system is split into three local components:

1. `spank-sensor-helper` reads the Apple Silicon sensor stream and emits structured slap events.
2. `spankd` receives those events over local Unix sockets, applies threshold, cooldown, source, and strategy policy, and selects validated audio clips.
3. `spankd` hands playback to `audio-helper`, while `badapple` talks to the daemon over the control socket for status and configuration changes.

The current sensor pipeline uses Apple HID and IOKit behavior consistent with the undocumented SPU device path described by the upstream IMU work. This is not a public Apple motion API.

## Audio Model

Production builds are embedded-media oriented and use canonical WAV assets rather than runtime MP3 decoding.

Current media behavior:

- built-in source: `sexy`
- special source: `chaos`
- optional build-time embedded source: `custom`
- optional developer-only runtime packs in a dedicated build mode

Supported strategies:

- `random`
- `escalation`

Current valid source/strategy pairs:

- `sexy` -> `random` or `escalation`
- `chaos` -> `random`
- `custom` -> `random` or `escalation` when compiled in
- runtime pack names -> `random` or `escalation` in developer builds with runtime packs enabled

All imported or embedded audio is normalized and validated against the same canonical profile:

- `48000 Hz`
- `16-bit PCM`
- `2-channel WAV`
- maximum clip duration: `10 seconds`

## Installation

### Quick Install From A Checkout

The current install path is the developer/alpha installer:

```bash
sudo ./scripts/dev_reinstall.sh
```

That script builds the native binaries, stages validated assets into your app-support directory, installs per-user LaunchAgents, and starts:

- `com.spank.spankd`
- `com.spank.spank-sensor-helper`

Installed locations:

- daemon: `~/Library/Application Support/spank/bin/spankd`
- sensor helper: `~/Library/Application Support/spank/bin/spank-sensor-helper`
- control client: `~/Library/Application Support/spank/bin/badapple`
- runtime dir: `~/Library/Application Support/spank/run`
- config: `~/Library/Application Support/spank/config.json`
- logs: `~/Library/Logs/spank/`

If `badapple` is not already on your shell `PATH`, add:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Build From Source

Build the native stack from a checkout:

```bash
zsh ./scripts/build_packtool_swift.sh
zsh ./scripts/build_audio_helper.sh
zsh ./scripts/build_sensor_stream.sh
zsh ./scripts/build_sensor_detector.sh
zsh ./scripts/build_spank_sensor_helper_native.sh
zsh ./scripts/build_spankd_native.sh
zsh ./scripts/build_badapple_native.sh
```

To validate the full native stack from source:

```bash
zsh ./scripts/validate_native_stack.sh
```

## Usage

Show the current status:

```bash
badapple status
```

Change source and strategy:

```bash
badapple mode sexy random
badapple mode sexy escalation
badapple mode chaos
```

Change sensitivity:

```bash
badapple sensitivity high
badapple sensitivity medium
badapple sensitivity low
badapple sensitivity 0.26
```

Current sensitivity presets:

- `high` -> `0.23`
- `medium` -> `0.28`
- `low` -> `0.33`

Pause and resume reactions without unloading services:

```bash
badapple pause
badapple resume
```

Manage services:

```bash
badapple start
badapple stop
badapple restart
```

See command help:

```bash
badapple help
```

## Custom Packs

### Embedded Custom Pack

To compile in a custom pack at build time:

```bash
./scripts/install_custom_pack.sh ~/Downloads/my-pack
sudo SPANK_BUILD_FEATURES='embed_media embed_custom_media' ./scripts/dev_reinstall.sh
badapple mode custom escalation
```

### Developer Runtime Packs

Developer builds can enable runtime pack installation:

```bash
sudo SPANK_BUILD_FEATURES='embed_media runtime_media_packs' ./scripts/dev_reinstall.sh
badapple pack install afterglow ~/Downloads/afterglow-audio
badapple restart
badapple mode afterglow random
```

Runtime packs are normalized and validated before they are accepted. Arbitrary raw media is not played directly.

Accepted import formats:

- `.wav`
- `.mp3`
- `.m4a`
- `.aac`
- `.aif`
- `.aiff`
- `.caf`

## Repository Layout

This repository now separates two concerns:

- product/runtime names: `spankd`, `spank-sensor-helper`, `badapple`
- internal toolkit namespace: `bruiseberry`

`bruiseberry` is the internal Apple-platform toolkit layer that contains the shared native models, daemon, helper, control client, sensor stream, detector, and media tooling.

Repository-owned media assets live under `assets/`.

## Operational Model

The default deployment is a pair of per-user LaunchAgents in the logged-in GUI session, not a broad root daemon.

Why:

- it matches the working sensor-access model on supported hardware
- it avoids a broad always-root runtime
- it keeps audio, control handling, and media validation in the unprivileged user context

This project intentionally does not treat the sensor path as a public Apple API integration. It uses a narrow, isolated implementation around an undocumented Apple Silicon SPU/HID route.

## Relevant Limitations

- only supported on appropriate Apple Silicon MacBook hardware
- not intended for Intel Macs
- may fail on unsupported M-series models or future hardware revisions
- depends on undocumented Apple internals for IMU access
- currently documented and shipped as an alpha/testing release

## License

This repository is licensed under the GNU Affero General Public License v3.0.

See [LICENSE](./LICENSE).
