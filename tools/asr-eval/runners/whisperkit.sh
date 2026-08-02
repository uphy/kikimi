#!/usr/bin/env bash
# WhisperKit (Argmax) -- Whisper large-v3-turbo on CoreML/ANE.
#
# `--chunking-strategy none` is deliberate: clips are already <=30s (one Whisper window), and
# leaving VAD chunking on would put WhisperKit's segmenter into the comparison instead of the
# acoustic model. See tools/asr-eval/README.md.
#
# First run downloads ~3GB into ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml.
set -euo pipefail

ROOT="${KIKIMI_ASR_EVAL_DIR:-$HOME/.local/state/kikimi/asr-eval}"
MODEL="${WHISPERKIT_MODEL:-large-v3_turbo}"
NAME="${WHISPERKIT_OUT:-whisperkit}"
OUT="$ROOT/hyp/$NAME"
REPORTS="$(mktemp -d)"
trap 'rm -rf "$REPORTS"' EXIT

command -v whisperkit-cli >/dev/null || {
  echo "whisperkit-cli not found -- brew install whisperkit-cli" >&2
  exit 1
}

mkdir -p "$OUT"
echo "running whisperkit-cli ($MODEL) over $ROOT/clips ..."
whisperkit-cli transcribe \
  --audio-folder "$ROOT/clips" \
  --model "$MODEL" \
  --language ja \
  --chunking-strategy none \
  --without-timestamps \
  --skip-special-tokens \
  --report --report-path "$REPORTS" >/dev/null

python3 - "$REPORTS" "$OUT" "$MODEL" <<'PY'
import json, pathlib, sys

reports, out, model = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3])
audio_s = infer_s = 0.0
count = 0
for report in sorted(reports.glob("*.json")):
    data = json.loads(report.read_text(encoding="utf-8"))
    (out / f"{report.stem}.txt").write_text(data.get("text", "").strip(), encoding="utf-8")
    timings = data.get("timings", {})
    audio_s += timings.get("inputAudioSeconds", 0.0)
    # Model load / prewarm is excluded: it is paid once per process, while the meeting
    # pipeline keeps the decoder warm across a whole recording.
    infer_s += timings.get("encoding", 0.0) + timings.get("decodingLoop", 0.0)
    count += 1

rtf = infer_s / audio_s if audio_s else 0.0
summary = (
    f"model: {model}\nclips: {count}\n"
    f"audio_seconds: {audio_s:.1f}\ndecode_seconds: {infer_s:.1f}\nrtf: {rtf:.4f}\n"
)
(out / "_timing.txt").write_text(summary, encoding="utf-8")
print(f"wrote {count} hypotheses to {out}")
print(summary, end="")
PY
