#!/usr/bin/env bash
# Multilingual Parakeet TDT v3 -- what a non-`ja` stt.language resolves to today
# (BatchAsrDecoder.resolveModelVersion). Included to check that the ja/non-ja split is
# earning its keep, not because v3 is a candidate for Japanese.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/_swift_harness.sh" AsrEvalHarness parakeet_v3
