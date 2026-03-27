# `spank` Daemon Refactor Instructions (Embedded Media, Least Privilege, Dependency Elimination)

## Purpose

This document defines the complete implementation instructions to refactor `taigrr/spank` into a daemon-capable system that:

- starts automatically,
- removes the broad root privilege scope,
- keeps only the minimum privileged code necessary for sensor access,
- eliminates the current filesystem-based media attack surface in production,
- uses embedded media as the supported production media model,
- replaces the current direct third-party CLI, audio, and sensor stacks with standard library or narrow internal packages where practical,
- removes runtime MP3 decoding from the supported build path,
- uses project-owned macOS-native playback and Apple Silicon sensor access code,
- fixes the concurrency, protocol, and deployment hardening issues identified in review,
- remains straightforward to build and operate.

This is an implementation instruction file, not a high-level summary. It is intended to be complete enough to hand off directly for execution.

---

# 1. Required End State

The refactored system must satisfy all of the following.

## 1.1 Runtime model

The program must no longer operate as a single broad-scope root process.

It must be split into:

1. **`spankd`** — the main long-running daemon, running as an **unprivileged per-user launch agent in the logged-in GUI session**.
2. **`spank-sensor-helper`** — a tiny sensor helper whose only responsibility is reading the hardware sensor stream and emitting sanitized slap events.
3. **`badapple`** — an optional local control utility for querying status and changing runtime settings.

## 1.2 Media model

The production daemon build must use **embedded media only**.

The daemon must not rely on arbitrary file paths, directory scanning, or user-provided media input at runtime.

Embedded media must be enabled through a compile-time build mode with a compile-time constant:

- `EMBED_MEDIA = true`

The build must use a dedicated build tag:

- `embed_media`

An optional additional embedded custom pack may be compiled in through a separate build tag:

- `embed_custom_media`

If present, the custom pack must still be embedded at build time and treated exactly like the built-in packs from the daemon's point of view. It must not reintroduce runtime path input, directory scanning, or ad hoc media loading.

## 1.3 Security model

The refactor must eliminate the following from the production daemon path:

- broad root execution,
- arbitrary custom media path handling,
- directory-based media loading,
- hand-rolled JSON protocol output,
- mutable unsynchronized package-level runtime globals,
- `/tmp`-based logs, sockets, or runtime state,
- root-owned logic that performs audio decode or playback,
- root-owned logic that parses general runtime control commands.

## 1.4 Automatic startup

The system must support automatic background startup through **two launchd services**:

- one service for the unprivileged daemon,
- one service for the sensor helper, normally under the same logged-in user session.

## 1.5 Operational model

The daemon must support:

- automatic start,
- crash restart,
- status checks,
- pause/resume,
- runtime tuning of selected settings,
- clean logging,
- controlled configuration reload,
- source-pack selection independent of playback strategy selection,
- a `chaos` source option that randomly selects across all embedded packs available in the build.

## 1.6 Dependency posture

The final implementation must eliminate the current direct dependency on:

- `github.com/charmbracelet/fang`
- `github.com/spf13/cobra`
- `github.com/gopxl/beep/v2`
- `github.com/taigrr/apple-silicon-accelerometer`

The target architecture should prefer:

- Go standard library for CLI, config, and control handling,
- narrow internal packages for media, playback, and sensor access,
- tiny macOS-native bridges where platform integration is required.

## 1.7 Documentation-backed boundaries

The replacement plan is not equally documented across all subsystems.

The implementation must distinguish between:

- replacements clearly supported by official Apple documentation,
- replacements that are technically plausible but rely on undocumented or private behavior.

Documented replacement surfaces:

- audio playback through Apple audio frameworks such as AVFoundation and AudioToolbox,
- generic HID or device access patterns through Apple-documented HID and IOKit interfaces.

Undocumented or only partially documented replacement surfaces:

- the exact Apple Silicon laptop IMU access path used by the current accelerometer integrations,
- SPU-specific HID services and properties such as `AppleSPUHIDDevice`, `AppleSPUHIDDriver`, or similar private keys or classes.

Observed reference implementations:

- the current external Go accelerometer dependency appears to use a thin IOKit and HID path plus private SPU device discovery,
- the original `olvvier/apple-silicon-accelerometer` implementation explicitly states that the IMU is not exposed through a public Apple API and is accessed through `AppleSPUHIDDevice` via IOKit HID.

Implementation rule:

- when using undocumented sensor behavior, keep that code isolated behind the helper and a narrow internal sensor package,
- explicitly document that this path may break on future macOS or hardware revisions,
- do not describe the internal sensor replacement as a fully public Apple API integration unless that is verified.

---

# 2. Non-Negotiable Design Rules

The implementation must follow these rules exactly.

## 2.1 Root scope must remain tiny

The system must not require root on hosts where the sensor path works in the logged-in user session.

If a future host-specific deployment proves that elevated privileges are required for sensor access, only the sensor helper may run as root.

The helper must not:

- decode audio,
- load media,
- scan filesystems for assets,
- expose a network service,
- parse arbitrary daemon control requests,
- handle user configuration directly,
- perform general logging to shared writable locations,
- manipulate arbitrary file paths.

## 2.2 The daemon must be unprivileged

`spankd` must run as a non-root per-user launch agent.

All of the following must happen in the unprivileged daemon only:

- slap cooldown logic,
- media selection,
- embedded audio validation,
- audio playback,
- runtime config handling,
- control API handling,
- command validation,
- pause/resume state,
- status reporting.

## 2.3 Production build must be embedded-media only

The production daemon build must not support the old runtime `--custom` or `--custom-files` behavior.

Those options must be removed from the production code path.

An embedded-at-build custom pack is allowed only if it is compiled into the binary through the supported custom-media build tag.

## 2.4 No service runtime paths under `/tmp`

The refactor must not place any of the following under `/tmp`:

- stdout/stderr log files,
- sockets,
- PID files,
- config,
- state,
- helper handshake files.

## 2.5 No hand-written JSON output

Every IPC and control response must be generated using `encoding/json`.

No `fmt.Fprintf(..."{...}")` style JSON construction may remain.

## 2.6 No unsynchronized mutable globals

No runtime setting may be read and written concurrently as a naked package global.

All runtime state must be managed through structured synchronization.

## 2.7 No heavyweight replacement frameworks

Do not replace the removed dependency stack with a similarly heavy general-purpose framework unless there is a compelling, documented reason.

Examples to avoid:

- replacing `cobra` with another large CLI framework,
- replacing `beep` with another large general-purpose audio framework,
- introducing a broad hardware abstraction layer when only minimal Apple Silicon sensor access is needed.

---

# 3. Final Architecture

## 3.1 Binaries

### 3.1.1 `spankd`

The main daemon.

Runs as:

- the logged-in user via a LaunchAgent in the `gui/$UID` domain

Responsibilities:

- receive sanitized slap events from helper,
- validate event payloads,
- apply cooldown and threshold policy,
- select an embedded clip based on the active source pack and playback strategy,
- safely validate and play embedded audio,
- play audio,
- maintain runtime config,
- expose local control API,
- provide status and health information,
- reload config when requested,
- log structured operational events.

### 3.1.2 `spank-sensor-helper`

Tiny sensor helper.

Runs as:

- the logged-in user via a LaunchAgent in the `gui/$UID` domain
- only escalate privileges if a specific deployment proves that the sensor path cannot function otherwise

Responsibilities:

- open the required sensor/HID/accelerometer interface,
- read sensor stream,
- normalize raw readings as needed,
- detect slap candidate events or emit minimally processed event data,
- send sanitized event messages to the daemon over local IPC,
- report helper health/errors.

### 3.1.3 `badapple`

Optional local control utility.

Runs as:

- normal local user with permission to access the daemon control socket,
- or a designated administrative group if stricter control is required.

Responsibilities:

- query daemon status,
- pause/resume daemon processing,
- update selected runtime settings,
- request reload,
- surface structured errors.

---

# 4. Required Project Layout

The codebase must be split into a clean multi-package structure.

Use this layout:

```text
cmd/
  spankd/
    main.go
  spank-sensor-helper/
    main.go
  badapple/
    main.go

internal/
  cli/
    parse.go
    usage.go
    commands.go
  config/
    config.go
  ipc/
    protocol.go
    server.go
    client.go
  audio/
    playback.go
    playback_darwin.go
    playback_stub.go
  media/
    embed_flag_true.go
    embed_custom_flag_true.go
    assets.go
    modes.go
    provider_embedded.go
    validate.go
  runtime/
    config.go
    state.go
    control.go
    daemon.go
  sensor/
    sensor.go
    darwin.go
    detector.go
    helper.go
    events.go
```

The current monolithic `main.go` must be dismantled and its responsibilities redistributed into these packages.

---

# 5. Embedded Media Build Model

## 5.1 Build tag

Use a dedicated Go build tag:

- `embed_media`

Optional embedded custom-media support must use an additional build tag:

- `embed_custom_media`

## 5.2 Compile-time constant

Create:

### `internal/media/embed_flag_true.go`

```go
//go:build embed_media

package media

const EMBED_MEDIA = true
```

This constant exists so the selected build behavior is explicit inside the codebase.

If custom embedded media is supported, create a second explicit compile-time constant such as:

### `internal/media/embed_custom_flag_true.go`

```go
//go:build embed_custom_media

package media

const EMBED_CUSTOM_MEDIA = true
```

This constant exists so custom-pack availability is explicit inside the codebase and testable without relying on file probing.

## 5.3 Embedded provider file

Create:

### `internal/media/provider_embedded.go`

```go
//go:build embed_media
```

This file must contain:

- the `go:embed` declarations,
- the embedded media provider implementation,
- source-pack and strategy-aware clip lookup,
- startup validation that required asset groups exist.

If custom embedded media is supported, the implementation may split custom-pack embedding into a second file such as `provider_embedded_custom.go` with `//go:build embed_custom_media`.

## 5.4 Build command

The supported production build command must be:

```bash
go build -tags embed_media -o spankd ./cmd/spankd
go build -o spank-sensor-helper ./cmd/spank-sensor-helper
go build -o badapple ./cmd/badapple
```

The supported embedded-custom build command must be:

```bash
go build -tags "embed_media embed_custom_media" -o spankd ./cmd/spankd
go build -o spank-sensor-helper ./cmd/spank-sensor-helper
go build -o badapple ./cmd/badapple
```

## 5.5 Production policy

The production daemon build must assume embedded media only.

No filesystem media provider must remain in the production daemon path.

If the custom embedded-media tag is enabled, the daemon may expose a `custom` source pack, but only from embedded assets shipped in the binary.

The supported dependency-reduced build must use:

- embedded WAV or PCM assets,
- internal playback code,
- no runtime MP3 decode path.

---

# 6. Media System Requirements

## 6.1 Media provider responsibilities

`internal/media` must expose a clean embedded-media API.

The package must provide:

- source-pack definitions,
- playback-strategy definitions,
- clip metadata,
- clip enumeration,
- random clip selection by source pack,
- escalation selection by source pack where supported,
- `chaos` selection across all embedded packs included in the build,
- opening or validating a selected embedded WAV or PCM clip for playback.

## 6.2 Suggested abstractions

The implementation must include structured types similar to:

```go
type Source string

type Strategy string

type Clip struct {
    Name string
    Data []byte
}
```

The exact shape may vary, but the package must support:

- validating available clips per source pack,
- choosing a clip without exposing raw embed internals everywhere,
- keeping media logic out of the daemon core,
- representing source-pack choice independently from playback strategy choice.

## 6.3 Source packs and strategies

The current built-in packs must continue to exist if they are already part of program behavior.

The refactor must support:

- built-in source packs such as `sexy`,
- an optional embedded `custom` source pack when compiled with the custom-media build tag,
- optional developer-only runtime pack names when compiled with a separate runtime-pack build tag,
- a `chaos` source option that randomly selects across all embedded packs available in the build,
- strategy selection independent of source-pack choice.

At minimum:

- `sexy` must support `random` and `escalation`,
- `custom` must support `random` and `escalation` when compiled into the build,
- optional runtime packs must support `random` and `escalation` when enabled in a non-production build,
- `chaos` must support `random`,
- removed legacy packs must not remain user-selectable in the supported CLI or config surface.

The media package must validate at startup that every required embedded source pack contains at least one clip.

If embedded assets are missing or empty, startup must fail fast with a clear error.

## 6.4 Asset format policy

The dependency-reduced build must not rely on runtime MP3 decoding.

Shipped embedded media must be converted to:

- WAV
- or raw PCM

The implementation must not keep MP3 as the supported production asset format.

## 6.5 Embedded asset validation safety

Even though media is embedded, asset parsing and validation entry points must still be guarded.

The validation path must contain panic or parser-failure containment so malformed shipped assets cannot kill the daemon process.

Implement a safe validation layer in `internal/media/validate.go`.

The validation layer must:

- recover panics where practical,
- convert parser failures into ordinary errors,
- return structured failure information,
- avoid crashing the daemon.

## 6.6 Internal audio package

Create an internal audio package responsible for playback.

`internal/audio` must provide:

- a Go-facing playback interface,
- a macOS-native playback implementation in `playback_darwin.go`,
- a stub or unsupported-platform implementation in `playback_stub.go`.

The rest of the application must not depend on third-party audio framework abstractions.

If subprocess playback is used temporarily, it must be documented as a transitional step rather than the final hardened design.

---

# 7. Sensor Helper Design

## 7.1 Responsibility boundary

The helper exists solely to isolate privileged sensor access.

The helper must do only the minimum necessary to read and forward events.

## 7.2 Allowed responsibilities

The helper may:

- initialize privileged sensor access,
- read accelerometer or HID events,
- normalize sample values,
- apply minimal slap candidate detection,
- emit structured event messages,
- log bounded operational errors,
- reconnect to the daemon if IPC is temporarily unavailable.

## 7.3 Forbidden responsibilities

The helper must not:

- load or decode media,
- parse general user commands,
- change runtime config directly,
- scan filesystem content,
- accept arbitrary path input,
- expose a general RPC service,
- write state or logs to `/tmp`,
- keep broad business logic that belongs in the daemon.

## 7.4 Event granularity

The helper should emit a narrow event payload.

Preferred model:

- helper does minimal processing,
- helper emits a slap event with normalized amplitude and timestamp,
- daemon decides how to apply policy.

This keeps policy and behavior in the unprivileged daemon.

## 7.5 Internal sensor package policy

The refactor must replace the current external accelerometer package with a narrow internal sensor implementation.

The internal sensor package must:

- expose only the minimal Apple Silicon sensor access `spank` requires,
- keep slap detection logic in Go where practical,
- avoid becoming a broad hardware abstraction library.

Small macOS-specific bridge code using cgo or Objective-C/C glue is allowed if needed.

---

# 8. IPC Requirements

## 8.1 Transport

Use a local Unix domain socket for helper-to-daemon communication.

Recommended location:

- `~/Library/Application Support/spank/run/spankd.sock`

Ownership and permissions must ensure that only the intended local principals can access it.

## 8.2 Event schema

Define a strict JSON protocol with typed messages.

The helper-to-daemon protocol must include at minimum:

- slap events,
- helper health or heartbeat events,
- helper error events.

A slap event must include fields similar to:

- message type,
- normalized amplitude,
- timestamp.

The exact field names may vary, but the schema must be fixed, typed, and validated.

## 8.3 Validation

The daemon must validate every incoming message before acting on it.

Validation must include:

- message type check,
- required fields present,
- numeric range validation where applicable,
- rejection of unknown or malformed payloads.

## 8.4 One-way privilege boundary

The helper socket protocol should be treated as a narrow event stream, not a general command tunnel.

Do not turn the helper into a generic privileged broker.

---

# 9. Daemon Runtime State Requirements

## 9.1 Replace globals

The daemon must replace all mutable unsynchronized package-level globals with structured runtime state.

This includes values such as:

- minimum amplitude,
- cooldown duration,
- speed ratio,
- volume scaling,
- pause state,
- active source pack,
- active playback strategy.

## 9.2 Synchronization model

Use one of the following:

- `sync.RWMutex` around structured state, or
- `atomic.Value` for config snapshots plus atomic primitives for simple flags.

The implementation should prefer immutable config snapshots if practical.

## 9.3 Recommended shape

A configuration structure must exist similar to:

```go
type RuntimeConfig struct {
    MinAmplitude  float64 `json:"min_amplitude"`
    CooldownMs    int     `json:"cooldown_ms"`
    SpeedRatio    float64 `json:"speed_ratio"`
    VolumeScaling bool    `json:"volume_scaling"`
    Source        string  `json:"source"`
    Strategy      string  `json:"strategy"`
}
```

A runtime state structure must exist to hold current configuration and paused/running state.

## 9.4 Access discipline

Every concurrent read or write of runtime settings must go through the structured state model.

No naked global reads or writes may remain in the daemon, playback code, or command handling paths.

---

# 10. Control Plane Requirements

## 10.1 Replace stdio control for daemon operations

The old `--stdio`-style control mechanism must not remain as the primary daemon control interface.

For daemon operation, use a local Unix socket control API and a small client utility (`badapple`).

## 10.2 Control commands

The daemon must support at minimum:

- `status`
- `pause`
- `resume`
- `reload`
- selected setting updates such as cooldown and threshold adjustment
- source-pack selection
- playback-strategy selection

## 10.3 Control protocol

The control protocol must use structured JSON request and response objects.

It must be encoded and decoded with `encoding/json` only.

## 10.4 Response shape

A structured response type must be used consistently.

For example, a response object may contain:

- status,
- error,
- data.

The exact field names may vary, but the response format must be fixed and machine-safe.

## 10.5 No format-string JSON

No response may be constructed via string interpolation pretending to be JSON.

This is a hard requirement.

---

# 11. Configuration Requirements

## 11.1 Configuration file

The daemon must use a small structured configuration file for runtime settings.

Recommended location:

- `~/Library/Application Support/spank/config.json`

## 11.2 Config contents

The configuration must include only operational settings relevant to the daemon, such as:

- source pack,
- playback strategy,
- min amplitude,
- cooldown,
- speed ratio,
- volume scaling.

It must not include runtime filesystem media path configuration in the production embedded-media build.

## 11.3 Permissions

The config file must be readable and writable by the logged-in user that owns the LaunchAgents.

Recommended ownership model:

- owner: the logged-in user
- group: the user's primary group
- mode: `0644` or stricter

## 11.4 Reload behavior

The daemon must support config reload through one of:

- `SIGHUP`,
- `badapple reload`,
- or both.

Reload must validate the new config before applying it.

Invalid config must not crash the daemon.

---

# 12. launchd Deployment Requirements

## 12.1 Two-service model

Deployment must use two separate launchd service definitions.

### Service 1: `com.spank.spankd.plist`

Runs:

- as a per-user LaunchAgent in the logged-in GUI session

Responsibilities:

- start the unprivileged daemon,
- keep it alive,
- ensure logs are captured safely,
- restart on crash.

### Service 2: `com.spank.spank-sensor-helper.plist`

Runs:

- as a per-user LaunchAgent in the logged-in GUI session by default
- only with elevated privileges if a host-specific deployment requires it and that exception is documented

Responsibilities:

- start the narrowly scoped sensor helper,
- keep it alive,
- reconnect if daemon restarts,
- remain tightly scoped.

## 12.2 Logging

Do not direct service logs to predictable files in `/tmp`.

Preferred choices:

- launchd-managed stdout/stderr capture,
- or controlled log files in the user's `~/Library/Logs/spank/` directory.

## 12.3 Service directories

If dedicated directories are created for sockets, logs, or config, they must be created with restrictive permissions and stable ownership.

---

# 13. Filesystem Layout Requirements

Use a fixed deployment layout.

Recommended:

- daemon binary: `~/Library/Application Support/spank/bin/spankd`
- helper binary: `~/Library/Application Support/spank/bin/spank-sensor-helper`
- control client: `~/Library/Application Support/spank/bin/badapple`
- config: `~/Library/Application Support/spank/config.json`
- socket/runtime directory: `~/Library/Application Support/spank/run/`
- logs if needed: `~/Library/Logs/spank/`

No production runtime component may depend on `/tmp`.

---

# 14. Required Code Migration Tasks

The implementation must complete all of the following migration tasks.

## 14.1 Remove old runtime custom media functionality

Delete or fully disable the production runtime code path for:

- `--custom`
- `--custom-files`
- directory scanning for media files,
- arbitrary path-based media loading.

These must not remain active in the daemonized production build.

Replace them, if custom support is desired, with a compile-time embedded custom-pack model controlled by the supported build tag.

## 14.2 Extract embedded media from monolithic main

Move all `go:embed` declarations and embedded clip logic out of the current monolithic `main.go` and into `internal/media/provider_embedded.go`.

## 14.3 Replace CLI dependencies

Remove:

- `github.com/charmbracelet/fang`
- `github.com/spf13/cobra`

Replace them with:

- standard library `flag`,
- `os.Args`,
- internal CLI parsing and usage helpers.

## 14.4 Replace external audio stack

Remove:

- `github.com/gopxl/beep/v2`
- runtime MP3 decoding from the supported build path

Replace them with:

- embedded WAV or PCM assets,
- internal media validation,
- internal macOS-native playback code.

## 14.5 Replace external accelerometer package

Remove:

- `github.com/taigrr/apple-silicon-accelerometer`

Replace it with:

- an internal Apple Silicon sensor package,
- narrow bridge code only where required,
- Go-level slap detection and policy logic.

## 14.6 Remove daemon-wide root check

The main daemon must no longer globally require `root`.

Any current root-gating logic in the monolithic runtime path must be removed from the daemon.

Only the helper should require elevated privileges.

## 14.7 Split playback from privileged sensor access

Any current logic that combines privileged startup with embedded audio parsing, validation, or playback must be split.

Playback must live only in the unprivileged daemon.

## 14.8 Replace raw stdio control handling

The current daemon-style stdio command model must be replaced for long-running service operation.

Introduce a proper local control interface and `badapple`.

## 14.9 Replace mutable globals

Every mutable global runtime setting must be replaced with structured synchronized state.

## 14.10 Replace hand-written JSON

All interpolated protocol JSON must be replaced by typed structs and `encoding/json`.

---

# 15. Reliability Requirements

## 15.1 Asset resilience

Malformed or problematic embedded media must not crash the daemon.

## 15.2 Helper crash isolation

If the helper crashes, the daemon must remain running and log the failure.

## 15.3 Daemon crash isolation

If the daemon crashes, the helper must not become a broad privileged process doing extra work.

It should simply fail or reconnect according to its narrow responsibility.

## 15.4 Restart tolerance

The daemon and helper must tolerate restart ordering issues.

If one process starts before the other, they must recover cleanly when their peer becomes available.

---

# 16. Logging Requirements

## 16.1 Structured logs

The daemon and helper must emit structured or at least consistently machine-parseable log messages.

## 16.2 Sensitive output discipline

Logs must not dump arbitrary unvalidated payloads in a way that breaks log structure.

## 16.3 Log destinations

Use either:

- launchd-managed logging,
- or controlled paths under `~/Library/Logs/spank/`.

Do not use `/tmp`.

---

# 17. Testing Requirements

The refactor is not complete until the following test coverage exists.

## 17.1 Concurrency testing

Run:

```bash
go test -race ./...
```

The daemon must be race-clean.

## 17.2 IPC validation testing

Add tests for:

- malformed JSON,
- unknown message types,
- missing required fields,
- invalid numeric ranges,
- helper reconnect behavior.

## 17.3 Control API testing

Add tests for:

- pause/resume,
- runtime config update,
- reload behavior,
- invalid command rejection,
- structured error responses.

## 17.4 Media testing

Add tests for:

- embedded media enumeration,
- empty mode failure,
- random clip selection,
- asset validation failure containment,
- `sexy` random selection,
- `sexy` escalation selection,
- `custom` random selection when compiled with the custom-media tag,
- `custom` escalation selection when compiled with the custom-media tag,
- runtime-pack random selection when compiled with the runtime-pack tag,
- runtime-pack escalation selection when compiled with the runtime-pack tag,
- `chaos` random selection across all embedded packs in the build.

## 17.5 CLI and dependency testing

Add tests for:

- help output,
- invalid flags,
- default flag values,
- source-pack and strategy parsing,
- absence of direct imports for the removed dependency set,
- successful stdlib-based CLI dispatch.

## 17.6 Audio and sensor testing

Add tests for:

- playback repeatability,
- explicit handling of playback failure,
- sensor initialization,
- sample acquisition,
- clean sensor shutdown,
- threshold behavior versus expected slap detection behavior.

## 17.7 Integration testing

Add integration tests for:

- daemon startup without root,
- helper startup in the logged-in user session,
- helper-to-daemon event flow,
- daemon behavior during helper downtime,
- launch ordering tolerance,
- end-to-end slap detection to sound playback on target Apple Silicon macOS systems.

---

# 18. Security Acceptance Criteria

The implementation is not complete until all of the following are true.

## 18.1 Privilege criteria

- `spankd` runs as non-root.
- `spank-sensor-helper` runs as the logged-in user on supported Apple Silicon hosts unless a documented exception requires elevation.
- the helper contains no media decode or playback logic.
- the helper is not a general privileged broker.

## 18.2 Media criteria

- production daemon uses embedded media only.
- no production arbitrary media path handling remains.
- no production directory media scanning remains.
- embedded asset validation occurs at startup.
- runtime MP3 decoding is gone from the supported build path.
- asset validation failures are contained.
- optional `custom` support, if enabled, is embedded at build time only.
- source-pack selection and playback-strategy selection are independent in the runtime model.
- `chaos` selects from the union of embedded packs included in the build.

## 18.3 Dependency criteria

- no direct dependency on `fang` remains.
- no direct dependency on `cobra` remains.
- no direct dependency on `beep` remains.
- no direct dependency on the current external accelerometer package remains.
- any remaining dependency has a documented reason.

## 18.4 Runtime criteria

- no mutable unsynchronized runtime globals remain.
- all command and IPC JSON uses typed encoding/decoding.
- malformed control input does not crash the daemon.

## 18.5 Deployment criteria

- no logs, sockets, or runtime state use `/tmp`.
- launchd deployment uses separate privileged and unprivileged services.
- service file locations and permissions are controlled.

## 18.6 Operational criteria

- daemon can start automatically.
- daemon can be paused/resumed.
- daemon can reload config safely.
- daemon tolerates helper disconnects and reconnects.

---

# 19. Implementation Sequence

Execute the refactor in this order.

## Step 1 — Remove runtime custom media support from production path

Delete or fully isolate the old filesystem custom media flags and code paths.

If custom media is still desired, replace it later with compile-time embedded custom-pack support.

This must happen first because it simplifies the rest of the refactor and removes the largest unnecessary production input surface.

## Step 2 — Replace CLI dependencies

Remove `fang` and `cobra`.

Replace them with standard-library parsing and internal CLI helpers.

## Step 3 — Create `internal/media`

Move embedded media declarations and selection logic into the new package.

Implement:

- `EMBED_MEDIA` compile-time constant,
- optional `EMBED_CUSTOM_MEDIA` compile-time constant,
- embedded provider,
- startup media validation,
- safe validation wrapper,
- WAV or PCM asset support.

## Step 4 — Replace the audio stack

Convert shipped assets to WAV or PCM and add internal playback support.

Replace `beep` and the runtime MP3 decode path.

## Step 5 — Replace the external accelerometer package

Create the internal Apple Silicon sensor package and bridge.

Keep slap detection policy in Go where practical.

## Step 6 — Create `spankd`

Build the unprivileged daemon binary.

Move into it:

- runtime config,
- cooldown logic,
- source-pack selection,
- playback-strategy selection,
- media decode/playback,
- status handling,
- pause/resume,
- config reload.

## Step 7 — Create `spank-sensor-helper`

Move privileged hardware access into the helper.

Keep it minimal.

## Step 8 — Implement IPC

Add the Unix domain socket protocol between helper and daemon.

Implement validation and reconnect behavior.

## Step 9 — Implement `badapple`

Add a clean local client for daemon control.

## Step 10 — Replace globals and ad hoc protocol code

Eliminate mutable package globals and replace all hand-written JSON.

## Step 11 — Add launchd deployment

Create the two-plist deployment model and remove the old root-daemon `/tmp` guidance.

## Step 12 — Run `go mod tidy` and inspect the dependency graph

Remove the now-obsolete direct requirements from `go.mod`, run `go mod tidy`, and inspect any remaining dependencies for a clear reason to exist.

## Step 13 — Test and harden

Run race tests, protocol tests, CLI tests, media tests, audio tests, sensor tests, and integration tests.

Only after this step is the refactor considered complete.

---

# 20. Final Production Policy

The final production system must follow this policy:

- **embedded media only**,
- **optional custom pack only when embedded at build time**,
- **embedded WAV or PCM assets instead of runtime MP3 decode**,
- **unprivileged main daemon**,
- **tiny privileged sensor helper only**,
- **stdlib-driven CLI and control paths where practical**,
- **internal macOS playback owned by the project**,
- **internal Apple Silicon sensor access owned by the project**,
- **typed local IPC only**,
- **no arbitrary media input**,
- **no `/tmp` service runtime state**,
- **no hand-built JSON**,
- **no unsynchronized mutable globals**,
- **no direct dependency on `fang`, `cobra`, `beep`, or the current external accelerometer package**.

This is the required implementation target.

Anything that preserves the old single-process root daemon behavior, keeps arbitrary media-path loading in production, treats build-time embedded custom media as runtime path input, retains the current direct dependency stack without a documented exception, or leaves runtime mutation unsynchronized does not meet the required design.
