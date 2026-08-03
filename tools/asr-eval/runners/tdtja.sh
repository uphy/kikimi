#!/usr/bin/env bash
# Current production baseline: parakeet-0.6b-ja, through Kikimi's own BatchAsrDecoder
# (so the low-energy split and CJK join are included, as they are in the app).
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/_swift_harness.sh" AsrEvalHarness tdtja
