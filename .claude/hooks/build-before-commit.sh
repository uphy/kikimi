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
#
# The failure output is capped (see MAX_* below). Hook stderr is fed back to the
# agent verbatim -- it does not go through the Bash tool's own output
# truncation -- so an unbounded dump lands in the context window whole. A
# SwiftLint run over an unexcluded agent worktree once emitted 114k lines /
# 33 MB here, which blew the context in a single tool result.
set -uo pipefail

# Keep the tail: build failures report the cause at the end.
readonly MAX_OUTPUT_LINES=200
readonly MAX_OUTPUT_BYTES=20000

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
  total_lines="$(printf '%s\n' "$build_output" | wc -l | tr -d ' ')"
  total_bytes="${#build_output}"

  # Two independent caps: line count catches many short lines, byte count
  # catches a few very long ones.
  trimmed="$(printf '%s\n' "$build_output" | tail -n "$MAX_OUTPUT_LINES")"
  trimmed="$(printf '%s' "$trimmed" | tail -c "$MAX_OUTPUT_BYTES")"

  if [[ "${#trimmed}" -lt "$total_bytes" ]]; then
    echo "[hook] build output truncated: showing the last ${#trimmed} of ${total_bytes} bytes (${total_lines} lines total). Re-run 'mise run build' to see it all." >&2
    echo "" >&2
  fi

  printf '%s\n' "$trimmed" >&2
  echo "" >&2
  echo "'mise run build' failed. Fix the build before committing." >&2
  exit 2
fi

exit 0
