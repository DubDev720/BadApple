#!/bin/zsh
set -euo pipefail

target_uid="${SUDO_UID:-$(id -u)}"
target_user="${SUDO_USER:-$USER}"
if [[ -n "${SUDO_USER:-}" ]]; then
  home_dir="$(dscl . -read "/Users/${target_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
else
  home_dir="${HOME}"
fi
if [[ -z "${home_dir}" ]]; then
  echo "Could not determine target home directory." >&2
  exit 1
fi

app_support_dir="${home_dir}/Library/Application Support/spank"
log_dir="${home_dir}/Library/Logs/spank"
launch_agents_dir="${home_dir}/Library/LaunchAgents"
local_bin_dir="${home_dir}/.local/bin"

/bin/launchctl bootout "gui/${target_uid}/com.spank.spank-sensor-helper" >/dev/null 2>&1 || true
/bin/launchctl bootout "gui/${target_uid}/com.spank.spankd" >/dev/null 2>&1 || true

/bin/rm -f "${launch_agents_dir}/com.spank.spankd.plist"
/bin/rm -f "${launch_agents_dir}/com.spank.spank-sensor-helper.plist"
/bin/rm -f "${app_support_dir}/bin/spankctl"
/bin/rm -f "${local_bin_dir}/badapple"
/bin/rm -f "${local_bin_dir}/spankctl"
/bin/rm -rf "${app_support_dir}"
/bin/rm -rf "${log_dir}"

echo "Removed per-user LaunchAgent deployment for com.spank.spankd and com.spank.spank-sensor-helper."
echo "Removed ${app_support_dir}, ${log_dir}, and ${local_bin_dir}/badapple."
echo "Reinstall with ./scripts/install_launchd_services.sh"
