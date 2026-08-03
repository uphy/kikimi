#!/usr/bin/env bash
# PreToolUse hook (Bash): before any command that runs `git commit`, refuse to
# commit on `main` and run `mise run build`, blocking the commit if it fails.
#
# stdin: hook JSON payload, e.g. {"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}
#
# - Commands that don't contain a `git commit` invocation exit 0 immediately.
# - `git commit-tree`, `git commit-graph`, `git log`, etc. do NOT match
#   (the regex requires "commit" to be its own word, followed by whitespace
#   or end of string).
# - On `main`, exit 2 with the `mise run wt` instructions. `main`'s ruleset
#   rejects the push anyway, so catching it here saves the detour. Set
#   KIKIMI_ALLOW_MAIN_COMMIT=1 to commit on `main` regardless.
# - A successful `mise run build` exits 0 (commit proceeds).
# - A failed `mise run build` prints the failure to stderr and exits 2,
#   which blocks the tool call.
set -uo pipefail

input="$(cat)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"

if [[ -z "$command_str" ]]; then
  exit 0
fi

# Match "git commit" as its own subcommand: preceded by start-of-string,
# whitespace, or a shell separator (; & |), and followed by whitespace or
# end-of-string. This avoids false positives like `git commit-tree`,
# `git commit-graph`, or `git log`.
if ! printf '%s' "$command_str" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+commit([[:space:]]|$)'; then
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root" || exit 0

# Refuse to commit on `main`. A detached HEAD or a failed lookup yields an empty
# branch name and is left alone -- this hook guards the common case, it is not a
# security boundary.
branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ "$branch" == "main" && "${KIKIMI_ALLOW_MAIN_COMMIT:-}" != "1" ]]; then
  cat >&2 <<'MSG'
Refusing to commit on `main`: this repository develops on worktrees and merges via PR
(CLAUDE.md "開発フロー: worktree + PR", docs/development-process.md 2.11).

  mise run wt <type>/<name>        # e.g. mise run wt fix/summary-pane-blank
  cd .claude/worktrees/<type>/<name>
  # move the work over (git stash push -u here, git stash pop there), then commit

`main`'s ruleset rejects direct pushes, so a commit made here cannot reach origin.
Set KIKIMI_ALLOW_MAIN_COMMIT=1 to override.
MSG
  exit 2
fi

if ! command -v mise >/dev/null 2>&1; then
  # mise not available in this environment; skip silently rather than block.
  exit 0
fi

echo "Running 'mise run build' before allowing 'git commit'..." >&2

if ! build_output="$(mise run build 2>&1)"; then
  echo "$build_output" >&2
  echo "" >&2
  echo "'mise run build' failed. Fix the build before committing." >&2
  exit 2
fi

exit 0
