#!/usr/bin/env bash
# Qwen3-ASR via MLX -- **draft generator, not a comparison arm**.
#
# Qwen3-ASR tops both published Japanese benchmarks this evaluation was set up against, but it
# has no Swift implementation: reaching it from Kikimi would mean a separate Python process or
# a port to MLX Swift. It is run here only to seed the reference blocks in review.md from a
# model that is *not* one of the candidates, so confirming the reference does not quietly
# favour whichever candidate seeded it.
#
# Output lands in hyp/qwen3_draft/, which means score.py will also report it. That is fine --
# read it as "what a non-shippable model would have given us", i.e. an upper bound, not as a
# fifth option.
#
#   tools/asr-eval/runners/qwen3_draft.sh
#   python3 tools/asr-eval/review.py --build --draft qwen3_draft
set -euo pipefail

ROOT="${KIKIMI_ASR_EVAL_DIR:-$HOME/.local/state/kikimi/asr-eval}"
MODEL="${QWEN3_ASR_MODEL:-mlx-community/Qwen3-ASR-1.7B-8bit}"
OUT="$ROOT/hyp/qwen3_draft"

command -v uv >/dev/null || { echo "uv not found -- brew install uv" >&2; exit 1; }
mkdir -p "$OUT"

echo "running $MODEL over $ROOT/clips (first run downloads ~2GB) ..."
uv run --quiet --with mlx-audio python - "$ROOT" "$OUT" "$MODEL" <<'PY'
import pathlib, sys, tempfile, time

from mlx_audio.stt.generate import generate_transcription
from mlx_audio.stt.utils import load_model

root, out, model_id = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
model = load_model(model_id)

clips = sorted((root / "clips").glob("clip_*.wav"))
audio_s = infer_s = 0.0
with tempfile.TemporaryDirectory() as scratch:
    sink = str(pathlib.Path(scratch) / "t")  # generate_transcription insists on writing a file
    for i, clip in enumerate(clips):
        start = time.monotonic()
        result = generate_transcription(
            model=model, audio=str(clip), output_path=sink, format="txt", language="Japanese"
        )
        elapsed = time.monotonic() - start
        text = (getattr(result, "text", None) or "").strip()
        (out / f"{clip.stem}.txt").write_text(text, encoding="utf-8")
        # The first clip carries lazy weight materialisation; excluded from the timing.
        if i > 0:
            infer_s += elapsed
            audio_s += (clip.stat().st_size - 44) / (16_000 * 2)
        print(f"{clip.stem} {elapsed:.2f}s: {text[:100]}")

rtf = infer_s / audio_s if audio_s else 0.0
summary = (
    f"model: {model_id}\nclips: {len(clips)}\n"
    f"audio_seconds: {audio_s:.1f}\ndecode_seconds: {infer_s:.1f}\nrtf: {rtf:.4f}\n"
)
(out / "_timing.txt").write_text(summary, encoding="utf-8")
print(summary, end="")
PY
