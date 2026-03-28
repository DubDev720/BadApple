#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: ./scripts/install_custom_pack.sh <audio-dir>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

source_dir="$1"
custom_dir="${repo_root}/assets/custom"
native_packtool="${repo_root}/bruiseberry/bin/packtool-swift"

if [[ ! -d "${source_dir}" ]]; then
  echo "Custom pack source directory not found: ${source_dir}" >&2
  exit 1
fi

./scripts/build_packtool_swift.sh
"${native_packtool}" normalize-dir -source-dir "${source_dir}" -output-dir "${custom_dir}"

"${native_packtool}" validate-embedded --repo-root "${repo_root}" --include-custom

count=$(find "${custom_dir}" -maxdepth 1 -name '*.wav' | wc -l | tr -d ' ')
echo "Installed ${count} canonical custom clips into ${custom_dir}"
echo "Next step:"
echo "  sudo SPANK_BUILD_FEATURES='embed_media embed_custom_media' ./scripts/dev_reinstall.sh"
