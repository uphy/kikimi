#!/usr/bin/env bash
# Detect whether Kikimi crashed (produced a macOS crash report) during a
# verification run. UI/session checks (capture.sh, verify_session.py) can
# all report PASS even after a crash-and-relaunch cycle -- e.g. a crash
# right after a segment is flushed to transcript.jsonl still leaves a
# structurally valid session folder. Bracketing a run with
# `crash_diff.sh snapshot` ... `crash_diff.sh check` catches that gap by
# diffing ~/Library/Logs/DiagnosticReports/Kikimi*.ips before/after.
#
# Usage:
#   crash_diff.sh snapshot
#       Record the current set of Kikimi*.ips crash reports as the
#       baseline (saved to "${TMPDIR:-/tmp}/kikimi-verify-crash-baseline.txt").
#       Run this before driving the app.
#
#   crash_diff.sh check
#       Compare the current set of Kikimi*.ips reports against the
#       baseline. Prints "no new crash reports" and exits 0 if unchanged.
#       If new reports appeared, prints each new report's path plus its
#       timestamp and exception type/message (parsed from the report's
#       line-1 JSON header and its "exception" body field), then exits 1.
#       Exits 2 (usage error, distinct from "crash found") if no baseline
#       exists yet -- run `snapshot` first.
set -euo pipefail

CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
BASELINE_FILE="${TMPDIR:-/tmp}/kikimi-verify-crash-baseline.txt"

list_reports() {
  # -print0/sort for a stable, whitespace-safe list; empty output (no
  # matches) is fine -- ls would error on no-match, find just returns nothing.
  find "$CRASH_DIR" -maxdepth 1 -name 'Kikimi*.ips' 2>/dev/null | sort
}

describe_report() {
  local path="$1"
  python3 - "$path" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as f:
    header_line = f.readline()
    body_text = f.read()

timestamp = "?"
try:
    header = json.loads(header_line)
    timestamp = header.get("timestamp", "?")
except json.JSONDecodeError:
    pass

exc_type = "?"
exc_message = ""
try:
    body = json.loads(body_text)
    exc = body.get("exception", {})
    exc_type = exc.get("type") or exc.get("signal") or "?"
    exc_message = exc.get("message", "")
except json.JSONDecodeError:
    pass

print(f"    timestamp={timestamp} exception={exc_type} message={exc_message}")
PYEOF
}

cmd="${1:-}"

case "$cmd" in
  snapshot)
    list_reports > "$BASELINE_FILE"
    count=$(wc -l < "$BASELINE_FILE" | tr -d ' ')
    echo "Snapshot saved: $count existing Kikimi*.ips report(s) recorded as baseline ($BASELINE_FILE)"
    ;;

  check)
    if [[ ! -f "$BASELINE_FILE" ]]; then
      echo "ERROR: no baseline found at $BASELINE_FILE -- run '$0 snapshot' before driving the app" >&2
      exit 2
    fi
    current_file=$(mktemp)
    trap 'rm -f "$current_file"' EXIT
    list_reports > "$current_file"

    new_reports=$(comm -13 "$BASELINE_FILE" "$current_file")
    if [[ -z "$new_reports" ]]; then
      echo "no new crash reports"
      exit 0
    fi

    echo "NEW CRASH REPORT(S) DETECTED:"
    while IFS= read -r report; do
      [[ -z "$report" ]] && continue
      echo "  $report"
      describe_report "$report"
    done <<< "$new_reports"
    exit 1
    ;;

  *)
    echo "Usage: $0 {snapshot|check}" >&2
    exit 2
    ;;
esac
