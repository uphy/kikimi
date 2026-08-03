#!/usr/bin/env bash
# Asks Kikimi whether it can be quit and replaced right now, and quits it when it can
# (`docs/design/46-control-socket.md`). Sourced by `.mise/tasks/apply`:
#
#   source .mise/tasks/_kikimi_control.sh
#   reason="$(kikimi_busy_reason)"      # empty = safe to restart
#   kikimi_stop_for_update              # exit 0 = stopped (or was not running), 1 = refused
#
# It can also be run directly as a check: exit 0 = free, exit 10 = busy (reason on stdout).
#
# The app answers over a Unix domain socket, from its own live state -- `WindowManager
# .recordingSessionId`, `DictationController.state`, and which paused sessions have a window open.
# `quit` decides and terminates in one MainActor hop, so no utterance can start between the check
# and the shutdown, and the shutdown runs `applicationShouldTerminate` (which flushes every open
# session) instead of killing the process outright the way `pkill` did.
#
# Everything under "Fallback" below is the pre-socket implementation, kept for the window where a
# build without the control socket is still installed. It guesses from disk -- `meta.json` states
# and dictation history folders that have no `entry.json` yet -- and needs grace windows to tell
# work in progress from crash leftovers. Delete it once no such build can be running.

readonly KIKIMI_CONTROL_SOCKET="${KIKIMI_CONTROL_SOCKET:-$HOME/.local/state/kikimi/control.sock}"
readonly KIKIMI_SESSIONS_DIR="${KIKIMI_SESSIONS_DIR:-$HOME/.local/state/kikimi/sessions}"
readonly KIKIMI_DICTATION_HISTORY_DIR="${KIKIMI_DICTATION_HISTORY_DIR:-$HOME/.local/state/kikimi/dictation/history}"
# Fallback-only grace windows. See the header: the socket path needs neither.
readonly KIKIMI_PAUSED_GRACE_SECONDS="${KIKIMI_PAUSED_GRACE_SECONDS:-1800}"
readonly KIKIMI_DICTATION_GRACE_SECONDS="${KIKIMI_DICTATION_GRACE_SECONDS:-120}"
# How long to wait for the process to go away after it accepted a quit.
readonly KIKIMI_QUIT_TIMEOUT_SECONDS="${KIKIMI_QUIT_TIMEOUT_SECONDS:-10}"

# MARK: - Control socket

# Sends one command and echoes the reply line. Returns 1 when the app cannot be asked at all (no
# socket, no `nc`, no reply) so callers fall back rather than treating silence as "free".
kikimi_control_request() {
  local verb="$1" reply
  [ -S "$KIKIMI_CONTROL_SOCKET" ] || return 1
  command -v nc >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  reply="$(printf '%s\n' "$verb" | nc -U -w 5 "$KIKIMI_CONTROL_SOCKET" 2>/dev/null | head -1)"
  [ -n "$reply" ] || return 1

  printf '%s' "$reply"
}

# Echoes a reason to stdout when Kikimi must not be restarted; echoes nothing when it is free.
kikimi_busy_reason() {
  if [ "${KIKIMI_APPLY_FORCE:-0}" = "1" ]; then
    return 0
  fi

  # Nothing to interrupt if the app is not running.
  if ! pgrep -x Kikimi >/dev/null 2>&1; then
    return 0
  fi

  local reply
  if reply="$(kikimi_control_request status)"; then
    if [ "$(printf '%s' "$reply" | jq -r '.busy // false')" = "true" ]; then
      printf '%s' "$reply" | jq -r '.reason // "busy"'
    fi
    return 0
  fi

  kikimi_fallback_busy_reason
}

# Stops Kikimi so its bundle can be replaced. Exit 0 = stopped, or was not running to begin with.
# Exit 1 = the app refused; the reason is echoed to stdout.
kikimi_stop_for_update() {
  if ! pgrep -x Kikimi >/dev/null 2>&1; then
    return 0
  fi

  local reply
  if [ "${KIKIMI_APPLY_FORCE:-0}" != "1" ] && reply="$(kikimi_control_request quit)"; then
    if [ "$(printf '%s' "$reply" | jq -r '.quit // false')" != "true" ]; then
      printf '%s' "$reply" | jq -r '.reason // "busy"'
      return 1
    fi
    kikimi_await_exit
    return 0
  fi

  # No control socket (or forced): re-check from disk, then kill. This is the old behaviour --
  # SIGTERM has no handler, so the app dies without flushing.
  local fallback_reason
  fallback_reason="$(kikimi_busy_reason)"
  if [ -n "$fallback_reason" ]; then
    printf '%s' "$fallback_reason"
    return 1
  fi
  pkill -x Kikimi
  kikimi_await_exit
  return 0
}

# Waits for the process to disappear, then escalates. `terminateLater` gives the app up to 5
# seconds to flush (06-ui-panels.md §9); this waits twice that before resorting to a signal.
kikimi_await_exit() {
  local deadline=$((KIKIMI_QUIT_TIMEOUT_SECONDS * 10))
  local waited=0

  while [ "$waited" -lt "$deadline" ]; do
    pgrep -x Kikimi >/dev/null 2>&1 || return 0
    sleep 0.1
    waited=$((waited + 1))
  done

  echo "Kikimi did not exit within ${KIKIMI_QUIT_TIMEOUT_SECONDS}s; killing it." >&2
  pkill -x Kikimi || true
  sleep 0.5
}

# MARK: - Fallback (pre-socket builds)

kikimi_fallback_busy_reason() {
  if ! command -v jq >/dev/null 2>&1; then
    # Fail closed: without a way to read meta.json, assume a meeting may be in progress.
    echo "cannot read session state (jq is not installed, and the app has no control socket)"
    return 0
  fi

  local reason
  reason="$(kikimi_fallback_session_reason)"
  [ -n "$reason" ] || reason="$(kikimi_fallback_dictation_reason)"
  [ -n "$reason" ] && echo "$reason"
  return 0
}

# A session in `.recording`, or one in `.paused` whose meta.json was written recently (an older
# paused session is a leftover -- one on this machine has sat there since 2026-07-07).
kikimi_fallback_session_reason() {
  [ -d "$KIKIMI_SESSIONS_DIR" ] || return 0

  local now meta session_id state age paused_reason=""
  now="$(date +%s)"

  for meta in "$KIKIMI_SESSIONS_DIR"/*/meta.json; do
    [ -f "$meta" ] || continue
    state="$(jq -r '.state // empty' "$meta" 2>/dev/null)" || continue
    session_id="$(basename "$(dirname "$meta")")"

    case "$state" in
      recording)
        echo "session $session_id is recording"
        return 0
        ;;
      paused)
        age=$((now - $(stat -f %m "$meta")))
        if [ "$age" -lt "$KIKIMI_PAUSED_GRACE_SECONDS" ] && [ -z "$paused_reason" ]; then
          paused_reason="session $session_id is paused, updated $((age / 60))m ago"
        fi
        ;;
    esac
  done

  [ -n "$paused_reason" ] && echo "$paused_reason"
  return 0
}

# `DictationHistoryStore.beginEntry()` creates the folder on hotkey-down and `finalize()` writes
# `entry.json` only after insertion, so a recent folder without one is an utterance in flight.
# Invisible when `dictation.history.enabled` is false -- the reason this fallback is not enough.
kikimi_fallback_dictation_reason() {
  [ -d "$KIKIMI_DICTATION_HISTORY_DIR" ] || return 0

  local now entry_dir age
  now="$(date +%s)"

  for entry_dir in "$KIKIMI_DICTATION_HISTORY_DIR"/*/; do
    [ -d "$entry_dir" ] || continue
    [ -f "$entry_dir/entry.json" ] && continue
    age=$((now - $(stat -f %m "$entry_dir")))
    if [ "$age" -lt "$KIKIMI_DICTATION_GRACE_SECONDS" ]; then
      echo "dictation entry $(basename "$entry_dir") is still being captured (started ${age}s ago)"
      return 0
    fi
  done
}

# MARK: - Direct invocation

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  reason="$(kikimi_busy_reason)"
  if [ -n "$reason" ]; then
    echo "Kikimi is busy: $reason"
    exit 10
  fi
  echo "Kikimi is free to restart"
  exit 0
fi
