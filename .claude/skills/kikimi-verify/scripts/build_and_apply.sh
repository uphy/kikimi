#!/usr/bin/env bash
# Build Kikimi and install/restart it via `mise run apply`.
# Usage: build_and_apply.sh [--force]
set -euo pipefail

# Now that the skill ships inside the repository, its own location identifies the checkout -- no
# hard-coded clone path, and a second checkout works without setting KIKIMI_REPO_ROOT.
repo_root="${KIKIMI_REPO_ROOT:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
cd "$repo_root"

if [ "${1:-}" = "--force" ]; then
  mise run -f apply
else
  mise run apply
fi
