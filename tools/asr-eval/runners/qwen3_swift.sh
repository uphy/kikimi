#!/usr/bin/env bash
# Qwen3-ASR via MLX in Swift -- the engine design 45 adopts for the second pass.
#
# Built with xcodebuild because SwiftPM does not compile Metal shaders: a `swift build` binary
# links mlx-swift without its `default.metallib` and traps at the first MLX call. The
# `-skipPackagePluginValidation` flag is required for mlx-swift's CudaBuild plugin, whose trust
# prompt a CLI build cannot answer.
#
# First run downloads the weights (~2GB for 1.7B/8bit) into ~/Library/Caches/qwen3-speech/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../../.mise/tasks/_developer_dir.sh
source "$repo_root/.mise/tasks/_developer_dir.sh"
resolve_developer_dir

export KIKIMI_ASR_EVAL_DIR="${KIKIMI_ASR_EVAL_DIR:-$HOME/.local/state/kikimi/asr-eval}"
# Matches Qwen3Variant.modelId. Default mirrors design 45 Q1's choice.
export QWEN3_MODEL_ID="${QWEN3_MODEL_ID:-aufklarer/Qwen3-ASR-1.7B-MLX-8bit}"
export QWEN3_OUT="${QWEN3_OUT:-qwen3_swift}"

probe="$repo_root/tools/asr-eval/qwen3-probe"
cd "$probe"
xcodebuild \
  -scheme Qwen3Probe \
  -destination 'platform=macOS' \
  -configuration Release \
  -derivedDataPath .dd \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build >/dev/null

exec "$probe/.dd/Build/Products/Release/Qwen3Probe"
