package cli

const Usage = `badapple manages the running spank services.

Quick start:
  badapple status                    Show mode, sensitivity, and service state
  badapple mode sexy random          Set source and strategy
  badapple sensitivity medium        Set a named sensitivity preset
  badapple pack list                 Show installed runtime packs
  badapple resume                    Re-enable slap reactions after pause

Commands:
  help                               Show this help menu
  status                             Show daemon status and current settings
  pause                              Disable slap reactions without stopping services
  resume                             Re-enable slap reactions after pause
  reload                             Reload config.json into the daemon
  mode <source> [strategy]           Set source and optional strategy
  sensitivity <preset|number>        Set min-amplitude by label or exact number
  set [flags]                        Update one or more runtime settings
  pack <list|install|remove>         Manage optional runtime WAV packs
  start                              Start the LaunchAgent services
  stop                               Stop the LaunchAgent services
  restart                            Restart the LaunchAgent services

Mode reference:
  Sources:     sexy, chaos, custom, <runtime-pack-name>
  Strategies:  random, escalation
  Valid pairs:
    sexy    -> random | escalation
    chaos   -> random
    custom  -> random | escalation  (after a custom build is installed)
    runtime -> random | escalation  (with a runtime_media_packs dev build)

Sensitivity reference:
  high    -> min-amplitude 0.23
  medium  -> min-amplitude 0.28
  low     -> min-amplitude 0.33
  numeric -> exact min-amplitude value from 0.0 to 1.0

Set flags:
  -source <sexy|chaos|custom|runtime-pack-name>
  -strategy <random|escalation>
  -min-amplitude <0.0-1.0>
  -cooldown <ms>
  -speed <ratio>
  -volume-scaling <true|false>

Examples:
  badapple status
  badapple mode sexy escalation
  badapple mode chaos
  badapple sensitivity high
  badapple sensitivity 0.26
  badapple set -cooldown 500 -speed 1.1
  badapple pack install afterglow ~/Downloads/afterglow-wavs
  badapple pack remove afterglow
  badapple pause
  badapple resume
  badapple restart

Embedded custom workflow:
  ./scripts/install_custom_pack.sh ~/Downloads/my-pack
  sudo SPANK_BUILD_TAGS='embed_media embed_custom_media' ./scripts/dev_reinstall.sh

Runtime pack workflow (developer-only):
  sudo SPANK_BUILD_TAGS='embed_media runtime_media_packs' ./scripts/dev_reinstall.sh
  badapple pack install afterglow ~/Downloads/afterglow-audio
  badapple restart
  badapple mode afterglow escalation

Pack import rules:
  Import formats: .wav, .mp3, .m4a, .aac, .aif, .aiff, .caf
  Installed format: 48000 Hz, 16-bit PCM, 2-channel WAV
  Max clip duration: 10 seconds
`
