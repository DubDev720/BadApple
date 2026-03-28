#!/bin/zsh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo." >&2
  exit 1
fi

/bin/launchctl bootout system/com.spank.spank-sensor-helper >/dev/null 2>&1 || true
/bin/launchctl bootout system/com.spank.spankd >/dev/null 2>&1 || true

/bin/rm -f /Library/LaunchDaemons/com.spank.spankd.plist
/bin/rm -f /Library/LaunchDaemons/com.spank.spank-sensor-helper.plist
/bin/rm -f /usr/local/libexec/spank/spankd
/bin/rm -f /usr/local/libexec/spank/spank-sensor-helper
/bin/rm -f /usr/local/bin/badapple
/bin/rm -f /usr/local/bin/spankctl

echo "Removed system LaunchDaemon deployment for com.spank.spankd and com.spank.spank-sensor-helper."
echo "Per-user LaunchAgent deployment can now be installed with ./scripts/install_launchd_services.sh"
