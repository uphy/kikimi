#!/usr/bin/env bash
# PreToolUse hook (Bash): block a bare `swift build` / `swift test` and point at the mise task.
#
# `xcode-select -p` deliberately stays on the Command Line Tools (`.mise/tasks/_developer_dir.sh`
# explains why), and that toolchain bundles neither the Metal compiler nor swift-testing. So a bare
# `swift build --build-tests` dies with "no such module 'Testing'" and a bare `swift build` produces
# an app whose first MLX call traps for want of a `default.metallib` -- while still exiting 0. The
# mise tasks resolve `DEVELOPER_DIR` to an Xcode.app first; these are the entry points that work.
#
# stdin: hook JSON payload, e.g. {"tool_name":"Bash","tool_input":{"command":"swift test"}}
#
# - `DEVELOPER_DIR=... swift test` is allowed: that is the deliberate, toolchain-pinned form, used
#   when a mise task cannot be (a scratch package outside the repo, an A/B against two manifests).
# - Only a command *position* match counts, so `grep "swift test" foo` or `--filter "swift build"`
#   pass through untouched.
set -uo pipefail

input="$(cat)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"

if [[ -z "$command_str" ]]; then
  exit 0
fi

# Already pinned to a toolchain, or already going through mise: nothing to say.
if printf '%s' "$command_str" | grep -q 'DEVELOPER_DIR='; then
  exit 0
fi

# `swift` at a command position: start of string/line, or after a shell separator, optionally
# behind `env` or VAR=value assignments.
if ! printf '%s' "$command_str" \
  | grep -Eq '(^|[;&|]|&&|\|\||[[:space:]]&&[[:space:]])[[:space:]]*(env[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*swift[[:space:]]+(build|test)([[:space:]]|$)'; then
  exit 0
fi

cat >&2 <<'MSG'
Blocked: a bare `swift build` / `swift test` uses the Command Line Tools toolchain, which has
neither the Metal compiler nor swift-testing.

  swift test   -> `mise run test`   (resolves DEVELOPER_DIR to an Xcode.app, sets KIKIMI_TEST_HIDDEN)
  swift build  -> `mise run build`  (also builds web/ and bundles/signs the .app)

If you genuinely need the raw command -- a scratch package outside the repo, or an A/B across two
manifests -- pin the toolchain explicitly:

  DEVELOPER_DIR=/Applications/Xcode*.app/Contents/Developer swift test
MSG
exit 2
