#!/usr/bin/env python3
"""Build the reference-confirmation worksheet, and split it back into ref/*.txt.

The reference has to be human-confirmed: every candidate model is wrong somewhere, and
scoring against any single model's output measures agreement with that model rather than
accuracy. So this writes one Markdown worksheet showing, per clip, what *every* model heard
plus the current pipeline's stored text -- disagreements between them are exactly where the
listener needs to pay attention -- and a reference block seeded from one model's output.

    python3 tools/asr-eval/review.py --build          # -> review.md
    # ... listen and edit the ``` blocks under "### reference" ...
    python3 tools/asr-eval/review.py --apply          # -> ref/clip_NN.txt

Seeding the reference from a model does bias it toward that model *if the reviewer rubber-
stamps it*. Showing all hypotheses side by side is the mitigation: a word only survives into
the reference unchallenged when every model agreed on it, and those are not the words that
decide the ranking. Use --draft to seed from a model that is not in the comparison at all
(see runners/qwen3_draft.sh) if you want that bias gone entirely.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path.home() / ".local/state/kikimi/asr-eval"

HEADER = """\
# ASR 評価: reference 確定シート

各クリップについて `### reference` の下のコードブロックを、音声を聞いて正しい書き起こしに直す。

- 再生: `afplay {clips_dir}/clip_NN.wav`
- 直し終えたら: `python3 tools/asr-eval/review.py --apply`
- 表記の方針: 実際に発話された通りに書く。句読点は付けても付けなくてもよい（既定の採点
  `cer_norm` は句読点を落として比較する）。数字は聞こえた通り（「じゅうろく」と読まれたら
  「16」でも「十六」でもよい / NFKC 後に一致すればよい）。言い淀み・フィラーは聞こえた分だけ書く。
- モデル間で食い違っている箇所が、そのまま精度差の出どころ。そこだけ聞き直せば足りる。

"""

CLIP_RE = re.compile(
    r"^## (?P<clip>clip_\d+).*?^### reference\s*^```\s*$(?P<ref>.*?)^```\s*$",
    re.MULTILINE | re.DOTALL,
)


def load_hyp(root: Path, model: str, clip_id: str) -> str:
    path = root / "hyp" / model / f"{clip_id}.txt"
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""


def discover_models(root: Path) -> list[str]:
    hyp_dir = root / "hyp"
    if not hyp_dir.is_dir():
        return []
    return sorted(d.name for d in hyp_dir.iterdir() if d.is_dir())


def build(root: Path, draft: str | None) -> int:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    models = discover_models(root)
    if not models:
        print(f"no hypotheses under {root/'hyp'} -- run the model runners first", file=sys.stderr)
        return 1
    if draft and draft not in models and not (root / "hyp" / draft).is_dir():
        print(f"draft model '{draft}' has no hypotheses; seeding from empty", file=sys.stderr)

    ref_dir = root / "ref"
    out = [HEADER.format(clips_dir=root / "clips")]
    for clip in manifest["clips"]:
        cid = clip["clip_id"]
        secs = clip["duration_ms"] / 1000
        out.append(
            f"## {cid}\n\n"
            f"`{clip['source']}` / {secs:.1f}s / session `{clip['session']}` "
            f"/ {clip['start_ms']}-{clip['end_ms']}ms\n\n"
        )
        for model in models:
            out.append(f"- **{model}**: {load_hyp(root, model, cid) or '_(empty)_'}\n")
        out.append(f"- _current pipeline_: {clip['baseline_text']}\n")

        # An already-confirmed reference wins over the draft, so rebuilding the worksheet
        # after adding a model never discards work the reviewer already did.
        existing = ref_dir / f"{cid}.txt"
        if existing.exists():
            seed = existing.read_text(encoding="utf-8").strip()
        elif draft:
            seed = load_hyp(root, draft, cid)
        else:
            seed = ""
        out.append(f"\n### reference\n\n```\n{seed}\n```\n\n")

    path = root / "review.md"
    path.write_text("".join(out), encoding="utf-8")
    confirmed = len(list(ref_dir.glob("*.txt"))) if ref_dir.is_dir() else 0
    print(f"wrote {path}")
    print(f"  clips: {len(manifest['clips'])}  models: {', '.join(models)}")
    print(f"  seeded from: {draft or '(empty)'}  already confirmed: {confirmed}")
    return 0


def apply(root: Path) -> int:
    path = root / "review.md"
    if not path.exists():
        print(f"no {path} -- run --build first", file=sys.stderr)
        return 1
    text = path.read_text(encoding="utf-8")
    ref_dir = root / "ref"
    ref_dir.mkdir(parents=True, exist_ok=True)

    written, empty = 0, []
    for match in CLIP_RE.finditer(text):
        clip_id = match.group("clip")
        ref = match.group("ref").strip()
        if not ref:
            empty.append(clip_id)
            continue
        (ref_dir / f"{clip_id}.txt").write_text(ref + "\n", encoding="utf-8")
        written += 1

    print(f"wrote {written} references to {ref_dir}")
    if empty:
        print(f"  still empty ({len(empty)}): {', '.join(empty)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument(
        "--draft",
        default="whisperkit",
        help="model whose output seeds the reference blocks ('none' to seed empty)",
    )
    args = ap.parse_args()

    if args.build == args.apply:
        ap.error("pass exactly one of --build / --apply")
    if args.build:
        return build(args.root, None if args.draft == "none" else args.draft)
    return apply(args.root)


if __name__ == "__main__":
    raise SystemExit(main())
