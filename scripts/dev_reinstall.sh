#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

echo "Developer reinstall"
echo "repo=${repo_root}"
echo "build_tags=${SPANK_BUILD_TAGS:-embed_media}"
echo

exec ./scripts/install_launchd_services.sh
