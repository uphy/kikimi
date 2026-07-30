#!/usr/bin/env bash
# Restart Kikimi without rebuilding (kills the running process and reopens the
# already-installed ~/Applications/Kikimi.app).
#
# Uses `open -g` so relaunching does NOT steal frontmost/focus (plain `open`
# activates the launched app by default). Pass --focus to restore the old
# activating behavior if you actually want to watch it come up in front.
set -euo pipefail

open_flag="-g"
if [ "${1:-}" = "--focus" ]; then
  open_flag=""
fi

if pgrep -x Kikimi >/dev/null 2>&1; then
  pkill -x Kikimi
  sleep 0.5
fi

open $open_flag ~/Applications/Kikimi.app
sleep 1.0
echo "Restarted Kikimi"
