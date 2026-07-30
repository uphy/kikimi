#!/usr/bin/env python3
"""
Validate a Kikimi session folder's structure against kikimi.md chapters 4-5:
  meta.json, audio/mic.wav, audio/system.wav, transcript.jsonl (and, once
  Phase 2 lands, refined.jsonl / summary.state.json / summary.md).

Usage: verify_session.py [session_id]
       With no argument, picks the most recently created session under
       ~/.local/state/kikimi/sessions/. Prints PASS/FAIL per check and exits
       1 if any required check fails.
"""
import sys
import os
import re
import json
import wave
import glob

SESSIONS_DIR = os.path.expanduser("~/.local/state/kikimi/sessions")
SEG_ID_RE = re.compile(r"^seg_\d{5}$")


def find_latest_session():
    candidates = sorted(glob.glob(os.path.join(SESSIONS_DIR, "*")), key=os.path.getmtime)
    return candidates[-1] if candidates else None


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" -- {detail}" if detail and not condition else ""))
    return condition


def verify_meta(session_dir):
    path = os.path.join(session_dir, "meta.json")
    if not check("meta.json exists", os.path.isfile(path)):
        return False
    with open(path, encoding="utf-8") as f:
        try:
            meta = json.load(f)
        except json.JSONDecodeError as e:
            return check("meta.json is valid JSON", False, str(e))
    check("meta.json is valid JSON", True)
    ok = True
    for field in ("id", "state", "created_at"):
        ok &= check(f"meta.json has '{field}'", field in meta)
    ok &= check("meta.json state is draft/recording/paused/ended",
                meta.get("state") in ("draft", "recording", "paused", "ended"),
                f"got {meta.get('state')!r}")
    return ok


def verify_audio(session_dir, mic_only=False):
    # Audio is written per recording segment: mic_NNN.wav / system_NNN.wav (kikimi.md ch.4,
    # one pair per meta.json recordings[] entry). The old single mic.wav/system.wav naming
    # predates pause/resume support.
    #
    # mic_only (the flag name is historical; it means "audio came from KIKIMI_TEST_INPUT"):
    # KIKIMI_TEST_INPUT is fed to *whichever streams the user's last input selection had enabled*
    # (`AudioCapture.init`, `state.yaml`'s `last_audio_input`) -- NOT to the mic stream only, which
    # is what this flag originally assumed. So which of the two files exists depends on the user's
    # setting, not on whether the pipeline worked: with the mic toggled off, mic_NNN.wav is legitimately
    # absent and demanding it made verify-smoke report FAIL on a perfectly healthy run
    # (observed 2026-07-30). In this mode, require at least one stream and warn about the other.
    ok = True
    present = {}
    for stream in ("mic", "system"):
        paths = sorted(glob.glob(os.path.join(session_dir, "audio", f"{stream}_*.wav")))
        present[stream] = paths
        if not mic_only:
            ok &= check(f"audio/{stream}_NNN.wav exists (>=1 segment)", len(paths) > 0)
        for path in paths:
            name = os.path.basename(path)
            size_ok = os.path.getsize(path) > 0
            ok &= check(f"audio/{name} is non-empty", size_ok)
            try:
                with wave.open(path, "rb") as wf:
                    rate_ok = wf.getframerate() == 16000
                    mono_ok = wf.getnchannels() == 1
                    ok &= check(f"audio/{name} is 16kHz", rate_ok, f"got {wf.getframerate()}")
                    ok &= check(f"audio/{name} is mono", mono_ok, f"got {wf.getnchannels()} channels")
            except wave.Error as e:
                ok &= check(f"audio/{name} is a valid WAV", False, str(e))
    if mic_only:
        total = len(present["mic"]) + len(present["system"])
        ok &= check("audio/{mic,system}_NNN.wav exists (>=1 segment in either stream)", total > 0)
        for stream, paths in present.items():
            if not paths:
                print(f"[WARN] audio/{stream}_NNN.wav absent ({stream} disabled in last_audio_input)")
    return ok


def verify_transcript(session_dir):
    path = os.path.join(session_dir, "transcript.jsonl")
    if not check("transcript.jsonl exists", os.path.isfile(path)):
        return False
    ok = True
    with open(path, encoding="utf-8") as f:
        lines = [line for line in f.read().splitlines() if line.strip()]
    ok &= check("transcript.jsonl has at least 1 segment", len(lines) > 0)
    for i, line in enumerate(lines):
        try:
            seg = json.loads(line)
        except json.JSONDecodeError as e:
            ok &= check(f"transcript.jsonl line {i} is valid JSON", False, str(e))
            continue
        for field in ("id", "start_ms", "end_ms", "speaker", "text", "confidence"):
            if field not in seg:
                ok &= check(f"transcript.jsonl line {i} has '{field}'", False)
        if "id" in seg:
            ok &= check(f"transcript.jsonl line {i} id format", bool(SEG_ID_RE.match(seg["id"])),
                        f"got {seg['id']!r}")
        if "speaker" in seg:
            ok &= check(f"transcript.jsonl line {i} speaker is mic/system",
                        seg["speaker"] in ("mic", "system"), f"got {seg['speaker']!r}")
    return ok


if __name__ == "__main__":
    argv = [a for a in sys.argv[1:]]
    mic_only = "--mic-only" in argv
    argv = [a for a in argv if a != "--mic-only"]
    session_dir = argv[0] if argv else None
    if session_dir is None:
        session_dir = find_latest_session()
        if session_dir is None:
            print(f"ERROR: no sessions found under {SESSIONS_DIR}", file=sys.stderr)
            sys.exit(1)
    elif not os.path.isabs(session_dir):
        session_dir = os.path.join(SESSIONS_DIR, session_dir)

    print(f"Verifying session: {session_dir}\n")
    ok = True
    ok &= verify_meta(session_dir)
    ok &= verify_audio(session_dir, mic_only=mic_only)
    ok &= verify_transcript(session_dir)

    print()
    print("Overall: PASS" if ok else "Overall: FAIL")
    sys.exit(0 if ok else 1)
