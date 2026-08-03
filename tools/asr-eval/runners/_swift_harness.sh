#!/usr/bin/env bash
# Shared entry point for the arms that run inside KikimiTests (see tools/asr-eval/README.md).
#
# Usage: _swift_harness.sh <test-filter> [KIKIMI_ASR_EVAL_MODEL]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export KIKIMI_ASR_EVAL_DIR="${KIKIMI_ASR_EVAL_DIR:-$HOME/.local/state/kikimi/asr-eval}"

filter="$1"
if [ $# -ge 2 ]; then
  export KIKIMI_ASR_EVAL_MODEL="$2"
fi

# The `cd` is load-bearing: invoked from inside .build/checkouts, `swift test` would resolve
# FluidAudio's own package instead of Kikimi's and try to build its CLI target, which does not
# compile under a CommandLineTools-only toolchain.
cd "$repo_root"
swift test --filter "$filter"
