#!/usr/bin/env bash
# Capture a Kikimi window by title substring (empty string matches the first
# Kikimi window found).
# Usage: capture.sh [title_substr] <output.png>
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -eq 1 ]; then
  title=""
  out="$1"
else
  title="$1"
  out="$2"
fi

python3 "$script_dir/kikimi_interact.py" capture "$title" "$out"
