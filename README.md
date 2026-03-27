<p align="center">
  <img src="doc/logo.png" alt="spank logo" width="200">
</p>

# spank

[Main README][readme-en-link]

Slap your MacBook, it yells back.

Uses the Apple Silicon accelerometer (Bosch BMI286 IMU via IOKit HID) to detect physical hits on your laptop and plays audio responses. The current architecture is split into `spankd`, `spank-sensor-helper`, and `badapple`.

## Requirements

- macOS on Apple Silicon (M2+)
- Go 1.26+ (if building from source)

## Build

Build from the current checkout:

```bash
go build -tags embed_media -o spankd ./cmd/spankd
go build -o spank-sensor-helper ./cmd/spank-sensor-helper
go build -o badapple ./cmd/badapple
```

## Usage

Run the daemon and helper against a writable runtime directory:

```bash
runtime_dir="$HOME/Library/Application Support/spank/run"
mkdir -p "$runtime_dir"
./spankd -runtime-dir "$runtime_dir"
./spank-sensor-helper -runtime-dir "$runtime_dir"
./badapple -runtime-dir "$runtime_dir" -command status
```

### Modes

The runtime model now separates source and strategy:

- Sources: `sexy`, `chaos`, `custom`, and optional runtime pack names
- Strategies: `random`, `escalation`
- `sexy` supports both `random` and `escalation`
- `chaos` supports `random`
- optional `custom` support is embedded at build time only
- optional runtime packs support `random` and `escalation` in developer builds

Use `badapple` to query status and change runtime settings such as source, strategy, cooldown, threshold, speed, and volume scaling.

Examples:

```bash
badapple status
badapple mode sexy escalation
badapple mode chaos
badapple sensitivity high
badapple sensitivity 0.26
badapple set -cooldown 500 -speed 1.1
badapple pack list
badapple pause
badapple resume
badapple restart
```

Sensitivity presets map to:

- `high` = `0.23`
- `medium` = `0.28`
- `low` = `0.33`

Custom pack workflow:

```bash
./scripts/install_custom_pack.sh ~/Downloads/my-pack
sudo SPANK_BUILD_TAGS='embed_media embed_custom_media' ./scripts/dev_reinstall.sh
badapple mode custom escalation
```

Runtime pack workflow for development:

```bash
sudo SPANK_BUILD_TAGS='embed_media runtime_media_packs' ./scripts/dev_reinstall.sh
badapple pack install afterglow ~/Downloads/afterglow-audio
badapple restart
badapple mode afterglow escalation
```

Both embedded custom packs and developer runtime packs are normalized into the same canonical format before they are accepted:

- accepted import formats: `.wav`, `.mp3`, `.m4a`, `.aac`, `.aif`, `.aiff`, `.caf`
- installed format: `48000 Hz`, `16-bit PCM`, `2-channel WAV`
- max clip duration: `10 seconds`
- pack install/build validation rejects anything outside that profile

## Running as a Service

The repository includes launchd agent templates in `launchd/com.spank.spankd.plist.template` and `launchd/com.spank.spank-sensor-helper.plist.template`, plus an installer script at `scripts/install_launchd_services.sh`.

On the target Apple Silicon MacBook, the working deployment model is a pair of per-user LaunchAgents bootstrapped into the logged-in GUI session. The earlier `_spank` system-LaunchDaemon model can enumerate the HID services but fails `IOHIDDeviceOpen` with `kIOReturnNotPermitted`, so it is no longer the default deployment path.

## How It Works

1. `spank-sensor-helper` reads raw accelerometer data directly from Apple Silicon sensor interfaces.
2. `spankd` receives sanitized slap events over a local Unix socket.
3. `spankd` applies threshold, cooldown, source, and strategy policy.
4. `spankd` plays an embedded WAV response through the internal AVFoundation-backed audio layer.
5. `badapple` queries status and updates runtime settings over the control socket.

## Credits

Sensor reading and vibration detection are based on the Apple Silicon accelerometer integration used by this codebase.

## License

MIT

<!-- Links -->
[readme-en-link]: ./README.md
