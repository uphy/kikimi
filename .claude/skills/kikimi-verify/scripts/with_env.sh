#!/usr/bin/env bash
# Launch a command (normally the Kikimi.app binary) with KEY=VAL vars applied
# as PROCESS-SCOPED env -- NOT via `launchctl setenv`. This is the whole point:
# `launchctl setenv` mutates the *global* GUI environment, so a forgotten
# `unsetenv` (crash, kill -9, race, or the user simply relaunching later) leaves
# KIKIMI_TEST_INPUT / KIKIMI_STUB_LLM active for EVERY future normal launch --
# the app then silently reads a dummy WAV instead of the real mic and looks like
# "書き起こしが一切できない". That footgun recurred repeatedly (2026-07-03, 2026-07-04).
#
# Process-scoped env removes the entire failure class: the vars exist ONLY inside
# the process this script spawns. A normal `open -a` / Spotlight / Dock launch can
# NEVER inherit them, and there is nothing global to clean up.
#
# KEY FACT (verified 2026-07-04): the old comment claiming "a directly-launched
# Kikimi.app doesn't inherit this shell's env vars" was WRONG. `open -a` does not
# pass env, but exec'ing the bundle binary directly DOES inherit it, process-scoped.
# So: launch the BINARY directly, never `open -a`, when test env is needed.
#
# Usage (pass the app BINARY path, not `open -a`):
#   with_env.sh KIKIMI_TEST_INPUT=/tmp/dummy.wav KIKIMI_STUB_LLM=1 -- \
#     ~/Applications/Kikimi.app/Contents/MacOS/Kikimi
#
# The command is launched detached (nohup + background) and this script returns
# after a short settle sleep; the app keeps running. To return to a clean state
# afterwards just `pkill -x Kikimi` and relaunch normally with `open -a` -- no
# unsetenv needed (nothing global was ever set).
set -euo pipefail

# Kill any running Kikimi first: a process already running won't magically pick up
# the new env, and `open -a` on a running app just re-activates it (the classic trap).
if pgrep -x Kikimi >/dev/null 2>&1; then
  pkill -x Kikimi
  for _ in $(seq 1 20); do
    pgrep -x Kikimi >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

envs=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  envs+=("$1"); shift
done

if [[ "${1:-}" == "--" ]]; then
  shift
else
  echo "usage: with_env.sh KEY=VAL [...] -- <app-binary-path> [args...]" >&2
  echo "  NOTE: pass the Kikimi.app binary directly, NOT 'open -a' (open does not pass env)." >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "usage: with_env.sh KEY=VAL [...] -- <app-binary-path> [args...]" >&2
  exit 1
fi

# Process-scoped: `env KEY=VAL ...` applies only to this child. nohup + background
# so it survives this script exiting. Nothing global is ever set, so nothing leaks.
nohup env "${envs[@]}" "$@" >/tmp/kikimi-test-launch.log 2>&1 &
disown || true

# Give the app a moment to actually fork and read the env before the caller proceeds.
sleep 2
