#!/usr/bin/env bash
# PreToolUse hook (Bash): before any command that runs `git commit`, run
# `mise run build` and block the commit if the build fails.
#
# stdin: hook JSON payload, e.g. {"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}
#
# - Commands that don't contain a `git commit` invocation exit 0 immediately.
# - `git commit-tree`, `git commit-graph`, `git log`, etc. do NOT match
#   (the regex requires "commit" to be its own word, followed by whitespace
#   or end of string).
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
