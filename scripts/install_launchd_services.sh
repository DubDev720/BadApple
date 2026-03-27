#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

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
runtime_dir="${app_support_dir}/run"
log_dir="${home_dir}/Library/Logs/spank"
bin_dir="${app_support_dir}/bin"
local_bin_dir="${home_dir}/.local/bin"
launch_agents_dir="${home_dir}/Library/LaunchAgents"
build_tags="${SPANK_BUILD_TAGS:-embed_media}"

/usr/bin/install -d -m 0755 "${app_support_dir}" "${runtime_dir}" "${log_dir}" "${bin_dir}" "${local_bin_dir}" "${launch_agents_dir}"
if [[ "${EUID}" -eq 0 ]]; then
  /usr/sbin/chown -R "${target_user}:staff" "${app_support_dir}" "${log_dir}" "${local_bin_dir}" "${launch_agents_dir}"
fi

if [[ " ${build_tags} " == *" embed_media "* ]]; then
  env HOME="${home_dir}" GOCACHE=/tmp/spank-go-build-cache GOSUMDB=off GOFLAGS=-mod=mod \
    go run -tags "${build_tags}" ./cmd/packtool validate-embedded
fi

env GOCACHE=/tmp/spank-go-build-cache GOSUMDB=off GOFLAGS=-mod=mod go build -tags "${build_tags}" -o /tmp/spankd ./cmd/spankd
env GOCACHE=/tmp/spank-go-build-cache GOSUMDB=off GOFLAGS=-mod=mod go build -o /tmp/spank-sensor-helper ./cmd/spank-sensor-helper
env GOCACHE=/tmp/spank-go-build-cache GOSUMDB=off GOFLAGS=-mod=mod go build -o /tmp/badapple ./cmd/badapple

/usr/bin/install -m 0755 /tmp/spankd "${bin_dir}/spankd"
/usr/bin/install -m 0755 /tmp/spank-sensor-helper "${bin_dir}/spank-sensor-helper"
/usr/bin/install -m 0755 /tmp/badapple "${bin_dir}/badapple"
/bin/rm -f "${bin_dir}/spankctl" "${local_bin_dir}/spankctl"
/bin/ln -sf "${bin_dir}/badapple" "${local_bin_dir}/badapple"
if [[ "${EUID}" -eq 0 ]]; then
  /usr/sbin/chown "${target_user}:staff" "${bin_dir}/spankd" "${bin_dir}/spank-sensor-helper" "${bin_dir}/badapple" "${local_bin_dir}/badapple"
fi

/usr/bin/install -m 0644 /dev/null "${log_dir}/spankd.log"
/usr/bin/install -m 0644 /dev/null "${log_dir}/spank-sensor-helper.log"
if [[ "${EUID}" -eq 0 ]]; then
  /usr/sbin/chown "${target_user}:staff" "${log_dir}/spankd.log" "${log_dir}/spank-sensor-helper.log"
fi

export REPO_ROOT="${repo_root}"
export SPANK_APP_SUPPORT_DIR="${app_support_dir}"
export SPANK_RUNTIME_DIR="${runtime_dir}"
export SPANK_LOG_DIR="${log_dir}"
export SPANK_BIN_DIR="${bin_dir}"
export SPANK_LAUNCH_AGENTS_DIR="${launch_agents_dir}"

python3 - <<'PY'
from pathlib import Path
import os

repo = Path(os.environ["REPO_ROOT"])
app_support_dir = Path(os.environ["SPANK_APP_SUPPORT_DIR"])
runtime_dir = Path(os.environ["SPANK_RUNTIME_DIR"])
log_dir = Path(os.environ["SPANK_LOG_DIR"])
bin_dir = Path(os.environ["SPANK_BIN_DIR"])
launch_agents_dir = Path(os.environ["SPANK_LAUNCH_AGENTS_DIR"])

replacements = {
    "__APP_SUPPORT_DIR__": str(app_support_dir),
    "__RUNTIME_DIR__": str(runtime_dir),
    "__LOG_DIR__": str(log_dir),
    "__BIN_DIR__": str(bin_dir),
}

for name in ("com.spank.spankd", "com.spank.spank-sensor-helper"):
    template = (repo / "launchd" / f"{name}.plist.template").read_text()
    for key, value in replacements.items():
        template = template.replace(key, value)
    (launch_agents_dir / f"{name}.plist").write_text(template)
PY
if [[ "${EUID}" -eq 0 ]]; then
  /usr/sbin/chown "${target_user}:staff" \
    "${launch_agents_dir}/com.spank.spankd.plist" \
    "${launch_agents_dir}/com.spank.spank-sensor-helper.plist"
fi

/bin/launchctl bootout "gui/${target_uid}/com.spank.spank-sensor-helper" >/dev/null 2>&1 || true
/bin/launchctl bootout "gui/${target_uid}/com.spank.spankd" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/${target_uid}" "${launch_agents_dir}/com.spank.spankd.plist"
/bin/launchctl bootstrap "gui/${target_uid}" "${launch_agents_dir}/com.spank.spank-sensor-helper.plist"
/bin/launchctl kickstart -k "gui/${target_uid}/com.spank.spankd"
/bin/launchctl kickstart -k "gui/${target_uid}/com.spank.spank-sensor-helper"

sleep 2

if /bin/launchctl print system/com.spank.spankd >/dev/null 2>&1 || /bin/launchctl print system/com.spank.spank-sensor-helper >/dev/null 2>&1; then
  echo "WARNING"
  echo "System launchd jobs com.spank.spankd or com.spank.spank-sensor-helper are still installed."
  echo "They can be removed separately if you no longer want the old system-daemon deployment."
  echo
fi

echo PATHS
printf 'target_user=%s\n' "${target_user}"
printf 'target_uid=%s\n' "${target_uid}"
printf 'build_tags=%s\n' "${build_tags}"
printf 'app_support=%s\n' "${app_support_dir}"
printf 'runtime=%s\n' "${runtime_dir}"
printf 'logs=%s\n' "${log_dir}"
printf 'bin=%s\n' "${bin_dir}"
printf 'cli_link=%s\n' "${local_bin_dir}/badapple"
echo
echo RUNTIME
ls -ld "${runtime_dir}" "${log_dir}" "${launch_agents_dir}/com.spank.spankd.plist" "${launch_agents_dir}/com.spank.spank-sensor-helper.plist"
echo
echo DAEMON
/bin/launchctl print "gui/${target_uid}/com.spank.spankd" | sed -n "1,80p"
echo
echo HELPER
/bin/launchctl print "gui/${target_uid}/com.spank.spank-sensor-helper" | sed -n "1,80p"
echo
echo SOCKETS
ls -l "${runtime_dir}" || true
echo
echo STATUS
"${bin_dir}/badapple" -runtime-dir "${runtime_dir}" -command status
echo
if [[ ":$PATH:" != *":${local_bin_dir}:"* ]]; then
  echo "PATH NOTE"
  echo "${local_bin_dir} is not currently on PATH."
  echo "Add this line to ~/.zshrc if you want to run badapple directly:"
  echo "export PATH=\"${local_bin_dir}:\$PATH\""
fi
