#!/usr/bin/env bash
# Cohere Transcribe 03-2026 (INT8 encoder). Already vendored in FluidAudio, so adopting it
# would need no new dependency -- but it is a separate pipeline from AsrModelVersion, hence
# its own harness. First run downloads several GB into ~/Library/Application Support/FluidAudio.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/_swift_harness.sh" AsrEvalCohereHarness
