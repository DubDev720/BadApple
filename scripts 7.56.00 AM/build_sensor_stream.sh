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

source_file="${repo_root}/bruiseberry/sensor-stream/main.m"
output_dir="${repo_root}/bruiseberry/bin"
binary_name="sensor-stream"
tmp_output="${output_dir}/${binary_name}.tmp"

mkdir -p "${output_dir}"
/bin/rm -f "${tmp_output}"

/usr/bin/clang \
  -fobjc-arc \
  -framework Foundation \
  -framework IOKit \
  -framework CoreFoundation \
  -isysroot "$(xcrun --show-sdk-path)" \
  -arch arm64 \
  -mmacosx-version-min=14.0 \
  -o "${tmp_output}" \
  "${source_file}"

/bin/mv -f "${tmp_output}" "${output_dir}/${binary_name}"

echo "built ${output_dir}/${binary_name}"
