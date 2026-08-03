#!/usr/bin/env bash
# Build Kikimi and install/restart it via `mise run apply`.
# Usage: build_and_apply.sh [--force]
set -euo pipefail

# Now that the skill ships inside the repository, its own location identifies the checkout -- no
# hard-coded clone path, and a second checkout works without setting KIKIMI_REPO_ROOT.
repo_root="${KIKIMI_REPO_ROOT:-$(cd "$(dirname "$0")/../../../.." && pwd)}"
cd "$repo_root"

status=0
if [ "${1:-}" = "--force" ]; then
  mise run -f apply || status=$?
else
  mise run apply || status=$?
fi

# Exit 10 means the running Kikimi refused to quit: it is recording, dictating, or has a paused
# meeting window open (`docs/design/46-control-socket.md`). `apply` prints which one. During a
# verification run that is usually the scenario's own test session, not a real meeting -- read the
# reason before overriding.
if [ "$status" -eq 10 ]; then
  echo "" >&2
  echo "[build_and_apply] Kikimi refused to quit (see the reason above). If that is this run's own" >&2
  echo "                  test session and not a real meeting, re-run with:" >&2
  echo "                  KIKIMI_APPLY_FORCE=1 $0 ${*:-}" >&2
fi

exit "$status"
