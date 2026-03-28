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

common_files=("${repo_root}"/bruiseberry/common/*.swift)
source_file="${repo_root}/bruiseberry/spank-sensor-helper/main.swift"
output_dir="${repo_root}/bruiseberry/bin"
cache_dir="${repo_root}/bruiseberry/.cache"
swift_module_cache="${cache_dir}/swift-modules"
clang_module_cache="${cache_dir}/clang-modules"
binary_name="spank-sensor-helper"
tmp_output="${output_dir}/${binary_name}.tmp"

mkdir -p "${output_dir}" "${swift_module_cache}" "${clang_module_cache}"
/bin/rm -f "${tmp_output}"

CLANG_MODULE_CACHE_PATH="${clang_module_cache}" /usr/bin/swiftc \
  -module-cache-path "${swift_module_cache}" \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macosx14.0 \
  -o "${tmp_output}" \
  "${common_files[@]}" \
  "${source_file}"

/bin/mv -f "${tmp_output}" "${output_dir}/${binary_name}"

echo "built ${output_dir}/${binary_name}"
