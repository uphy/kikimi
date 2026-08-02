#!/usr/bin/env python3
"""Cut evaluation clips out of recorded Kikimi sessions.

The clips are the audio the batch (second-pass) decoder actually sees: windows of
consecutive confirmed segments from one source (mic or system), cut on segment
boundaries so no clip starts or ends mid-sentence.

Clip length is capped at 30s on purpose. Every candidate model can decode 30s as a
*single* window -- Cohere Transcribe hard-caps at 35s, Whisper's window is 30s, and
Kikimi's own BatchAsrDecoder splits above 15s. Staying under every model's chunking
threshold keeps the comparison about acoustic modelling rather than about whose
chunk-merge heuristic is better.

Audio is copied byte-wise from the source WAV (16kHz mono PCM s16le), so clips are
bit-identical to what the app recorded -- no resampling, no re-encoding.

Usage:
    python3 tools/asr-eval/make_clips.py --count 20
    python3 tools/asr-eval/make_clips.py --sessions <id> <id> --count 20
"""

from __future__ import annotations

import argparse
import json
import random
import struct
import sys
import wave
from dataclasses import dataclass, asdict
from pathlib import Path

SESSIONS_DIR = Path.home() / ".local/state/kikimi/sessions"
DEFAULT_OUT = Path.home() / ".local/state/kikimi/asr-eval"

# A clip must be long enough to be a meaningful decode but short enough that every
# model handles it in one window (see module docstring).
MIN_CLIP_MS = 15_000
MAX_CLIP_MS = 30_000
# Reject windows that are mostly silence -- they measure nothing and inflate CER
# denominators unevenly across models (some emit nothing, some hallucinate).
MIN_SPEECH_RMS = 0.005
MIN_CHARS = 20


@dataclass
class Clip:
    clip_id: str
    session: str
    source: str  # "mic" | "system"
    start_ms: int
    end_ms: int
    duration_ms: int
    segment_ids: list[str]
    baseline_text: str  # current pipeline output; a hint for review, NOT the reference
    stt_source: str | None  # "batch" when the session already ran two-pass decode
    rms: float


def load_segments(session_dir: Path) -> list[dict]:
    path = session_dir / "transcript.jsonl"
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def audio_path(session_dir: Path, source: str, start_ms: int) -> tuple[Path, int] | None:
    """Return (wav path, offset within that recording) for an absolute session offset.

    Sessions can hold several recording runs (`recordings[]` in meta.json), each with
    its own `<source>_NNN.wav` and a `start_ms_offset` into the session timeline.
    """
    meta = json.loads((session_dir / "meta.json").read_text(encoding="utf-8"))
    recordings = sorted(meta.get("recordings", []), key=lambda r: r.get("index", 0))
    if not recordings:
        return None
    chosen = None
    for rec in recordings:
        if start_ms >= rec.get("start_ms_offset", 0):
            chosen = rec
        else:
            break
    if chosen is None:
        return None
    wav = session_dir / "audio" / f"{source}_{chosen.get('index', 0):03d}.wav"
    if not wav.exists():
        return None
    return wav, start_ms - chosen.get("start_ms_offset", 0)


def build_windows(segments: list[dict], source: str) -> list[tuple[list[dict], int, int]]:
    """Greedily pack consecutive same-source segments into <=MAX_CLIP_MS windows."""
    segs = [s for s in segments if s.get("speaker") == source]
    segs.sort(key=lambda s: s.get("start_ms", 0))
    windows: list[tuple[list[dict], int, int]] = []
    current: list[dict] = []
    for seg in segs:
        if not current:
            current = [seg]
            continue
        start = current[0]["start_ms"]
        if seg["end_ms"] - start <= MAX_CLIP_MS:
            current.append(seg)
            continue
        span = current[-1]["end_ms"] - start
        if span >= MIN_CLIP_MS:
            windows.append((current, start, current[-1]["end_ms"]))
        current = [seg]
    if current:
        span = current[-1]["end_ms"] - current[0]["start_ms"]
        if span >= MIN_CLIP_MS:
            windows.append((current, current[0]["start_ms"], current[-1]["end_ms"]))
    return windows


def read_pcm(wav_path: Path, start_ms: int, end_ms: int) -> tuple[bytes, int, float]:
    """Slice raw PCM frames and return (frames, sample_rate, rms)."""
    with wave.open(str(wav_path), "rb") as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 1:
            raise SystemExit(
                f"{wav_path}: expected 16-bit mono PCM, got "
                f"{w.getsampwidth()*8}-bit / {w.getnchannels()}ch"
            )
        rate = w.getframerate()
        first = int(start_ms * rate / 1000)
        count = int((end_ms - start_ms) * rate / 1000)
        total = w.getnframes()
        if first >= total:
            return b"", rate, 0.0
        count = min(count, total - first)
        w.setpos(first)
        frames = w.readframes(count)
    if not frames:
        return frames, rate, 0.0
    samples = struct.unpack(f"<{len(frames)//2}h", frames)
    mean_sq = sum(s * s for s in samples) / len(samples)
    rms = (mean_sq**0.5) / 32768.0
    return frames, rate, rms


def write_wav(path: Path, frames: bytes, rate: int) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames)


def collect_candidates(session_ids: list[str]) -> list[Clip]:
    candidates: list[Clip] = []
    for sid in session_ids:
        session_dir = SESSIONS_DIR / sid
        segments = load_segments(session_dir)
        if not segments:
            print(f"  skip {sid}: no transcript", file=sys.stderr)
            continue
        for source in ("mic", "system"):
            for segs, start, end in build_windows(segments, source):
                text = "".join(s.get("text", "") for s in segs)
                if len(text) < MIN_CHARS:
                    continue
                resolved = audio_path(session_dir, source, start)
                if resolved is None:
                    continue
                wav, local_start = resolved
                frames, rate, rms = read_pcm(wav, local_start, local_start + (end - start))
                if not frames or rms < MIN_SPEECH_RMS:
                    continue
                candidates.append(
                    Clip(
                        clip_id="",
                        session=sid,
                        source=source,
                        start_ms=start,
                        end_ms=end,
                        duration_ms=end - start,
                        segment_ids=[s.get("id", "") for s in segs],
                        baseline_text=text,
                        stt_source=segs[0].get("stt_source"),
                        rms=round(rms, 5),
                    )
                )
    return candidates


def pick_balanced(candidates: list[Clip], count: int, mic_count: int, seed: int) -> list[Clip]:
    """Sample `count` clips spread across sessions, with a floor on mic clips.

    mic and system are acoustically different problems -- mic is close-talk from one
    speaker, system is the compressed far-end mix of a conference call. A model can win
    one and lose the other, so both must be represented. Recorded sessions are heavily
    system-weighted (that is what meetings look like), so mic gets an explicit quota
    rather than a proportional share, otherwise a mic-side regression is invisible here.
    """
    rng = random.Random(seed)

    def take(source: str, want: int) -> list[Clip]:
        buckets: dict[str, list[Clip]] = {}
        for c in candidates:
            if c.source == source:
                buckets.setdefault(c.session, []).append(c)
        for items in buckets.values():
            rng.shuffle(items)
        keys = sorted(buckets)
        out: list[Clip] = []
        while len(out) < want and any(buckets[k] for k in keys):
            for k in keys:
                if len(out) >= want:
                    break
                if buckets[k]:
                    out.append(buckets[k].pop())
        return out

    mic = take("mic", min(mic_count, count))
    system = take("system", count - len(mic))
    picked = mic + system
    picked.sort(key=lambda c: (c.source, c.session, c.start_ms))
    return picked


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", nargs="*", default=None, help="session ids (default: auto-pick)")
    ap.add_argument("--count", type=int, default=24)
    ap.add_argument("--mic-count", type=int, default=6, help="minimum mic clips (rest are system)")
    ap.add_argument("--seed", type=int, default=20260802)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    session_ids = args.sessions
    if not session_ids:
        # Sessions that actually hold both a long transcript and its audio.
        session_ids = [
            d.name
            for d in sorted(SESSIONS_DIR.iterdir())
            if (d / "transcript.jsonl").exists()
            and (d / "transcript.jsonl").stat().st_size > 20_000
            and (d / "audio").is_dir()
            and any((d / "audio").glob("*.wav"))
        ]
        print(f"auto-selected {len(session_ids)} sessions")

    print("scanning sessions...")
    candidates = collect_candidates(session_ids)
    print(f"  {len(candidates)} candidate windows")
    if len(candidates) < args.count:
        print(f"warning: only {len(candidates)} candidates for --count {args.count}", file=sys.stderr)

    picked = pick_balanced(candidates, args.count, args.mic_count, args.seed)

    clips_dir = args.out / "clips"
    clips_dir.mkdir(parents=True, exist_ok=True)
    for i, clip in enumerate(picked, start=1):
        clip.clip_id = f"clip_{i:02d}"
        session_dir = SESSIONS_DIR / clip.session
        wav, local_start = audio_path(session_dir, clip.source, clip.start_ms)
        frames, rate, _ = read_pcm(wav, local_start, local_start + clip.duration_ms)
        write_wav(clips_dir / f"{clip.clip_id}.wav", frames, rate)

    manifest = {
        "seed": args.seed,
        "count": len(picked),
        "total_ms": sum(c.duration_ms for c in picked),
        "clips": [asdict(c) for c in picked],
    }
    (args.out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    total_s = manifest["total_ms"] / 1000
    by_source: dict[str, int] = {}
    for c in picked:
        by_source[c.source] = by_source.get(c.source, 0) + 1
    print(f"wrote {len(picked)} clips ({total_s:.0f}s total) to {clips_dir}")
    print(f"  by source: {by_source}")
    print(f"  sessions:  {len({c.session for c in picked})}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
