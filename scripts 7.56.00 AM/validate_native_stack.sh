#!/bin/zsh

# Copyright (C) 2026 Jocelyn Dubeau
#
# This file is part of BadApple (aka Spank 2.0).
#
# BadApple is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# BadApple is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BadApple.  If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/spank-native-validate.XXXXXX")"
runtime_dir="${runtime_root}/run"
packs_dir="${runtime_root}/packs"
config_path="${runtime_root}/config.json"
daemon_log="${runtime_root}/spankd.log"
helper_log="${runtime_root}/helper.log"

mkdir -p "${runtime_dir}" "${packs_dir}"
rm -f "${config_path}" "${daemon_log}" "${helper_log}"

cleanup() {
  if [[ -n "${helper_pid:-}" ]]; then
    kill "${helper_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${daemon_pid:-}" ]]; then
    kill "${daemon_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -d "${runtime_root:-}" ]]; then
    rm -rf "${runtime_root}"
  fi
}
trap cleanup EXIT

zsh ./scripts/build_packtool_swift.sh
zsh ./scripts/build_spankd_native.sh
zsh ./scripts/build_badapple_native.sh
zsh ./scripts/build_audio_helper.sh
zsh ./scripts/build_sensor_stream.sh
zsh ./scripts/build_sensor_detector.sh
zsh ./scripts/build_spank_sensor_helper_native.sh

./bruiseberry/bin/packtool-swift validate-embedded --repo-root "${repo_root}"

./bruiseberry/bin/spankd \
  -runtime-dir "${runtime_dir}" \
  -config "${config_path}" \
  -assets-dir "${repo_root}/assets" \
  -packs-dir "${packs_dir}" \
  -audio-helper "${repo_root}/bruiseberry/bin/audio-helper" \
  >"${daemon_log}" 2>&1 &
daemon_pid=$!

sleep 1

./bruiseberry/bin/badapple -runtime-dir "${runtime_dir}" -command status
./bruiseberry/bin/badapple -runtime-dir "${runtime_dir}" -command update -source chaos
./bruiseberry/bin/badapple -runtime-dir "${runtime_dir}" -command update -min-amplitude 0.23
./bruiseberry/bin/badapple -runtime-dir "${runtime_dir}" -command status
./bruiseberry/bin/badapple detector status

./bruiseberry/bin/spank-sensor-helper -runtime-dir "${runtime_dir}" -native-detector \
  >"${helper_log}" 2>&1 &
helper_pid=$!

sleep 2

if ! kill -0 "${helper_pid}" >/dev/null 2>&1; then
  echo "native helper exited unexpectedly" >&2
  cat "${helper_log}" >&2
  exit 1
fi

echo "native stack validation passed"
