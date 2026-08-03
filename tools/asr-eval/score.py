#!/usr/bin/env python3
"""Score model hypotheses against the human-confirmed reference.

Two CER variants are reported because a single number is misleading here:

  cer_norm  -- primary. Punctuation, spaces and symbols are stripped before scoring.
               The candidate models disagree about punctuation by design (Parakeet TDT
               Japanese emits none, Whisper and Cohere insert it), and Kikimi runs an
               LLM refinement pass afterwards that rewrites punctuation anyway. Scoring
               it would rank models on a property the product does not care about.
  cer_raw   -- secondary, NFKC only. Kept so a model that wins on cer_norm purely by
               omitting punctuation is still visible.

The edit-operation breakdown matters as much as the totals: Whisper-family models fail
by hallucinating text into silence (insertions), while TDT models fail by dropping words
(deletions). Those two failure modes are not equally bad for a meeting transcript that
feeds an LLM summariser -- a dropped word is unrecoverable, an inserted one is noise the
summariser may repeat as fact.

Usage:
    python3 tools/asr-eval/score.py
    python3 tools/asr-eval/score.py --models tdtja whisperkit
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ROOT = Path.home() / ".local/state/kikimi/asr-eval"

# Stripped for cer_norm. Covers both the ASCII and CJK forms; NFKC runs first, so this
# only needs the post-normalisation shapes.
PUNCT = set("、。，．・「」『』（）()［］[]｛｝{}〈〉《》!?！？…‥ー-―–—~〜/\\:;：；\"'“”‘’,.")
SPACE = set(" \t\n　")


def normalize(text: str, strip_punct: bool) -> str:
    text = unicodedata.normalize("NFKC", text)
    chars = []
    for ch in text:
        if ch in SPACE:
            continue
        if strip_punct and (ch in PUNCT or unicodedata.category(ch).startswith("P")):
            continue
        chars.append(ch)
    return "".join(chars)


@dataclass
class EditCounts:
    sub: int
    ins: int
    dele: int
    ref_len: int

    @property
    def total(self) -> int:
        return self.sub + self.ins + self.dele

    @property
    def cer(self) -> float:
        return self.total / self.ref_len if self.ref_len else 0.0


def edit_distance(ref: str, hyp: str) -> EditCounts:
    """Levenshtein with operation counts, O(len(ref) * len(hyp)) time, O(len(hyp)) space."""
    n, m = len(ref), len(hyp)
    # Each cell holds (cost, sub, ins, del).
    prev: list[tuple[int, int, int, int]] = [(j, 0, j, 0) for j in range(m + 1)]
    for i in range(1, n + 1):
        cur: list[tuple[int, int, int, int]] = [(i, 0, 0, i)]
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                cand = prev[j - 1]
            else:
                pc, ps, pi, pd = prev[j - 1]
                cand = (pc + 1, ps + 1, pi, pd)
            dc, ds, di, dd = prev[j]
            deletion = (dc + 1, ds, di, dd + 1)
            ic, isub, iins, idel = cur[j - 1]
            insertion = (ic + 1, isub, iins + 1, idel)
            best = min(cand, deletion, insertion, key=lambda t: t[0])
            cur.append(best)
        prev = cur
    cost, sub, ins, dele = prev[m]
    return EditCounts(sub=sub, ins=ins, dele=dele, ref_len=n)


def load_hyp(root: Path, model: str, clip_id: str) -> str:
    path = root / "hyp" / model / f"{clip_id}.txt"
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""


def pairwise(root: Path, clips: list[dict], models: list[str]) -> int:
    """Model-vs-model disagreement, needing no reference at all.

    Two models that agree are usually both right -- independent systems rarely invent the
    same wrong characters. So a model far from everyone else is the suspicious one, and a
    tight cluster is a good bet for what was actually said. This does not prove accuracy,
    but it does show whether the models differ enough for a hand-built reference to change
    any decision.
    """
    print("pairwise disagreement (CER-style, punctuation stripped)\n")
    width = max(len(m) for m in models) + 2
    print(" " * width + "".join(f"{m:>14}" for m in models))
    mean_dist: dict[str, float] = {}
    for a in models:
        cells = []
        dists = []
        for b in models:
            if a == b:
                cells.append(f"{'-':>14}")
                continue
            agg = EditCounts(0, 0, 0, 0)
            for clip in clips:
                cid = clip["clip_id"]
                counts = edit_distance(
                    normalize(load_hyp(root, b, cid), True), normalize(load_hyp(root, a, cid), True)
                )
                agg = EditCounts(
                    agg.sub + counts.sub, agg.ins + counts.ins, agg.dele + counts.dele,
                    agg.ref_len + counts.ref_len,
                )
            cells.append(f"{agg.cer*100:>13.1f}%")
            dists.append(agg.cer)
        mean_dist[a] = sum(dists) / len(dists) if dists else 0.0
        print(f"{a:<{width}}" + "".join(cells))

    print("\nmean distance to the other models (low = closest to consensus):")
    for model, dist in sorted(mean_dist.items(), key=lambda t: t[1]):
        print(f"  {model:<14}{dist*100:.1f}%")
    return 0


def discover_models(root: Path) -> list[str]:
    hyp_dir = root / "hyp"
    if not hyp_dir.is_dir():
        return []
    return sorted(d.name for d in hyp_dir.iterdir() if d.is_dir())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    ap.add_argument("--models", nargs="*", default=None)
    ap.add_argument(
        "--ref-model",
        default=None,
        help="score against this model's output instead of ref/ (no human confirmation needed; "
        "reports agreement with that model, NOT accuracy)",
    )
    ap.add_argument(
        "--pairwise",
        action="store_true",
        help="print the model-vs-model disagreement matrix instead of scoring",
    )
    args = ap.parse_args()

    root: Path = args.root
    manifest_path = root / "manifest.json"
    if not manifest_path.exists():
        print(f"no manifest at {manifest_path} -- run make_clips.py first", file=sys.stderr)
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    clips = manifest["clips"]

    models = args.models or discover_models(root)
    if not models:
        print(f"no hypotheses under {root/'hyp'}", file=sys.stderr)
        return 1

    if args.pairwise:
        return pairwise(root, clips, models)

    # --ref-model stands in for the human reference. It answers "how far is each model from
    # this one", which ranks models only to the extent the stand-in is itself right. Use it to
    # decide whether the differences are even large enough to be worth confirming by hand.
    ref_model = args.ref_model
    if ref_model:
        models = [m for m in models if m != ref_model]
        print(f"scoring against model '{ref_model}' (agreement, not accuracy)\n")

    ref_dir = root / "ref"
    missing_ref = [] if ref_model else [
        c["clip_id"] for c in clips if not (ref_dir / f"{c['clip_id']}.txt").exists()
    ]
    if missing_ref:
        print(
            f"missing reference for {len(missing_ref)} clips "
            f"(e.g. {', '.join(missing_ref[:3])}) -- confirm them first",
            file=sys.stderr,
        )
        if len(missing_ref) == len(clips):
            return 1

    rows = []
    totals: dict[str, dict[str, EditCounts]] = {
        m: {"norm": EditCounts(0, 0, 0, 0), "raw": EditCounts(0, 0, 0, 0)} for m in models
    }
    empty_out: dict[str, int] = {m: 0 for m in models}

    for clip in clips:
        cid = clip["clip_id"]
        if ref_model:
            ref_text = load_hyp(root, ref_model, cid)
            if not ref_text:
                continue
        else:
            ref_path = ref_dir / f"{cid}.txt"
            if not ref_path.exists():
                continue
            ref_text = ref_path.read_text(encoding="utf-8").strip()
        for model in models:
            hyp_path = root / "hyp" / model / f"{cid}.txt"
            hyp_text = hyp_path.read_text(encoding="utf-8").strip() if hyp_path.exists() else ""
            if not hyp_text:
                empty_out[model] += 1
            row = {
                "clip_id": cid,
                "model": model,
                "source": clip["source"],
                "session": clip["session"],
                "duration_ms": clip["duration_ms"],
            }
            for variant, strip in (("norm", True), ("raw", False)):
                counts = edit_distance(normalize(ref_text, strip), normalize(hyp_text, strip))
                agg = totals[model][variant]
                totals[model][variant] = EditCounts(
                    agg.sub + counts.sub,
                    agg.ins + counts.ins,
                    agg.dele + counts.dele,
                    agg.ref_len + counts.ref_len,
                )
                row[f"cer_{variant}"] = round(counts.cer, 4)
                if variant == "norm":
                    row.update(sub=counts.sub, ins=counts.ins, dele=counts.dele, ref_len=counts.ref_len)
            rows.append(row)

    out_csv = root / "results.csv"
    with out_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    scored = len({r["clip_id"] for r in rows})
    print(f"scored {scored}/{len(clips)} clips x {len(models)} models -> {out_csv}\n")

    header = f"{'model':<14}{'CER(norm)':>11}{'CER(raw)':>10}{'sub':>7}{'ins':>7}{'del':>7}{'empty':>7}"
    print(header)
    print("-" * len(header))
    for model in sorted(models, key=lambda m: totals[m]["norm"].cer):
        n, r = totals[model]["norm"], totals[model]["raw"]
        print(
            f"{model:<14}{n.cer*100:>10.2f}%{r.cer*100:>9.2f}%"
            f"{n.sub:>7}{n.ins:>7}{n.dele:>7}{empty_out[model]:>7}"
        )

    print("\nby source (CER norm):")
    for source in ("mic", "system"):
        per_model = []
        for model in models:
            agg = EditCounts(0, 0, 0, 0)
            for row in rows:
                if row["model"] == model and row["source"] == source:
                    agg = EditCounts(
                        agg.sub + row["sub"],
                        agg.ins + row["ins"],
                        agg.dele + row["dele"],
                        agg.ref_len + row["ref_len"],
                    )
            if agg.ref_len:
                per_model.append((model, agg.cer))
        if per_model:
            cells = "  ".join(f"{m}={c*100:.2f}%" for m, c in sorted(per_model, key=lambda t: t[1]))
            print(f"  {source:<7}{cells}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
