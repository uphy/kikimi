#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): run swiftlint on the file that was just
# written/edited, and surface violations back to Claude.
#
# stdin: hook JSON payload, e.g. {"tool_name":"Edit","tool_input":{"file_path":"/abs/path/Foo.swift"}}
#
# - Non-.swift files (or missing file_path) exit 0 immediately, no output.
# - Clean files exit 0 immediately, no output.
# - Files with any swiftlint violation print the violations to stderr and
#   exit 2, which Claude Code surfaces back to the model as feedback.
set -uo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

# Only care about Swift source files.
if [[ -z "$file_path" || "$file_path" != *.swift ]]; then
  exit 0
fi

if [[ ! -f "$file_path" ]]; then
  exit 0
fi

# Resolve the repo root from this script's own location so this works
# regardless of the hook's invocation cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root" || exit 0

if ! command -v mise >/dev/null 2>&1; then
  # mise not available in this environment; skip silently rather than block.
  exit 0
fi

# SourceKit framework path for CommandLineTools-only environments
# (mirrors .mise/tasks/lint).
if [ -d "/Library/Developer/CommandLineTools/usr/lib" ]; then
  export DYLD_FRAMEWORK_PATH="/Library/Developer/CommandLineTools/usr/lib"
fi

output="$(mise exec -- swiftlint lint --quiet --force-exclude "$file_path" 2>&1)"

# `--force-exclude` makes swiftlint itself refuse to lint a path covered by
# .swiftlint.yml's top-level `excluded:` list (e.g. KikimiTests/) -- it prints
# "No lintable files found at paths: ..." and exits non-zero. That's swiftlint
# honoring the project's own exclusion list working as intended, not a
# violation in the edited file, so don't treat it as one.
if [[ "$output" == *"No lintable files found"* ]]; then
  exit 0
fi

if [[ -n "$output" ]]; then
  echo "swiftlint found violation(s) in $file_path:" >&2
  echo "$output" >&2
  exit 2
fi

exit 0
