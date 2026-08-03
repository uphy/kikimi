#!/usr/bin/env bash
# SessionStart hook: remove the worktrees whose PR the user merged since the last session
# (docs/development-process.md 2.11).
#
# stdin: hook JSON payload (unused -- the reaper works out the repository from git itself).
#
# Prints only what it actually removed, so a session that has nothing to clean up starts with no
# extra context. Never fails the session: the reaper exits 0 on every path, including no network,
# no gh, and no worktrees.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reaper="$script_dir/../../.mise/tasks/wt/reap"

[ -x "$reaper" ] || exit 0

# Run it directly rather than through `mise run`: mise prints its own task banner, which would be
# noise on every single session start.
"$reaper" --quiet 2>/dev/null || true

exit 0
