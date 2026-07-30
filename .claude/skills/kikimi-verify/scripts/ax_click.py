#!/usr/bin/env python3
"""
AX (Accessibility) button click helper -- the reliable fallback when click.py's
CGEventPost coordinate clicks don't reach Kikimi (frontmost stuck on the
terminal/multiplexer instead of Kikimi). Targets the window by TITLE via
System Events rather than by window index: System Events' window order does
not reliably match CGWindowList's, so index-based targeting ("window 1") has
been observed to silently click the wrong window or throw -1719 "invalid
index" (2026-07-03).

Non-invasive by default: does NOT call activate() before listing/clicking.
System Events GUI scripting reaches a background (non-frontmost) process
as-is -- verified 2026-07-05 (clicked a header button with Kikimi
non-frontmost; the click fired and frontmost stayed unchanged throughout).
Pass --focus (anywhere in argv) to restore the old activate()-first behavior
if AX scripting doesn't reach Kikimi in some environment.

Usage:
    ax_click.py list <window_title_substr> [--focus]
        List the buttons in the window's header (group 1) as "index:label",
        where label is the button's AX `help` text (falling back to
        `description` if help is unset).

    ax_click.py click <window_title_substr> <button> [--focus]
        Click a button in group 1 of the matched window. <button> may be
        either:
          - a NAME to match against AX `help` (falling back to `description`)
            -- exact match preferred, then substring match. PREFERRED: names
            are stable across session states, unlike index (see the label
            contract below).
          - a 1-based integer INDEX into group 1's buttons (kept for backward
            compatibility; indexes shift with session state -- see below).

    ax_click.py click <window_title_substr> <button> <expected_state> [session_dir] [timeout_sec] [--focus]
        Same, then poll meta.json's `state` field until it equals
        expected_state (default timeout 5s). Exits non-zero if it never
        matches -- use this instead of eyeballing a screenshot to judge
        whether a header button (pause/resume/end) actually fired.
        session_dir defaults to the most recently modified session under
        ~/.local/state/kikimi/sessions/ when omitted OR passed as "" -- use
        "" explicitly if you want a custom timeout_sec but don't know/care
        about the session_dir, e.g. `click "" 会議終了 ended "" 30` (a bare
        number in the session_dir slot, e.g. `... ended 30`, is NOT a
        timeout -- it is parsed as a literal path and fails).

Button label contract (AX `help`, exact strings Kikimi sets on every header
button -- see SKILL.md section 4):
    録音開始 / 録音再開 / 一時停止 / 会議終了 / 再開 (Ended-state rescue) /
    タイトルを編集 / 録音入力を設定 / タイトル案を採用 (proposal badge, only
    when a proposal is showing)

Prefer clicking by name over index: header button composition/order is
state-dependent (e.g. Recording: 1=edit, 2=audio input, 3=pause, 4=end
meeting / Ended: 1=edit, 2=resume) and additionally shifts when a title
proposal badge appears, so a hardcoded index silently drifts across states.

Known gap: popovers on a nonactivating panel (e.g. the speaker-rename
popover) do not appear in the AX tree at all -- there is no AX-based click
for those. Verify that flow via its resulting state file instead.
"""
import sys
import os
import json
import time
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import ax_list_buttons, ax_click_button, activate  # noqa: E402

SESSIONS_DIR = os.path.expanduser("~/.local/state/kikimi/sessions")


def find_latest_session():
    candidates = sorted(glob.glob(os.path.join(SESSIONS_DIR, "*")), key=os.path.getmtime)
    return candidates[-1] if candidates else None


def _clean(value):
    """AppleScript returns the literal string "missing value" for a property
    it couldn't read (e.g. a button with no `help` set); normalize that to
    an empty string so callers can treat it as falsy."""
    return "" if value == "missing value" else value


def parse_buttons(raw):
    """Parse ax_list_buttons()'s raw "index:name|description|help" lines
    into a list of {"index", "name", "description", "help"} dicts."""
    buttons = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        idx_str, _, rest = line.partition(":")
        parts = rest.split("|")
        name = parts[0] if len(parts) > 0 else ""
        description = parts[1] if len(parts) > 1 else ""
        help_text = parts[2] if len(parts) > 2 else ""
        buttons.append({
            "index": int(idx_str),
            "name": _clean(name),
            "description": _clean(description),
            "help": _clean(help_text),
        })
    return buttons


def resolve_button_index(title_substr, button_arg):
    """Resolve the <button> CLI argument to a 1-based index. Integer-looking
    arguments are returned as-is (backward compatible with index-based
    callers). Otherwise button_arg is matched as a NAME against AX `help`
    first, then `description`, trying an exact match before falling back to
    a substring match. Exits with an error if zero or more-than-one buttons
    match a substring (ambiguous)."""
    try:
        return int(button_arg)
    except ValueError:
        pass

    buttons = parse_buttons(ax_list_buttons(title_substr))

    for field in ("help", "description"):
        for b in buttons:
            if b[field] == button_arg:
                return b["index"]
    for field in ("help", "description"):
        matches = [b for b in buttons if button_arg in b[field]]
        if len(matches) == 1:
            return matches[0]["index"]
        if len(matches) > 1:
            print(f"ERROR: name {button_arg!r} matches multiple buttons via '{field}': "
                  f"{[(m['index'], m[field]) for m in matches]}", file=sys.stderr)
            sys.exit(1)

    available = [(b["index"], b["help"] or b["description"]) for b in buttons]
    print(f"ERROR: no button matching name {button_arg!r} found. Available: {available}",
          file=sys.stderr)
    sys.exit(1)


def poll_state(session_dir, expected_state, timeout_sec):
    meta_path = os.path.join(session_dir, "meta.json")
    deadline = time.time() + timeout_sec
    last_seen = None
    while time.time() < deadline:
        try:
            with open(meta_path, encoding="utf-8") as f:
                meta = json.load(f)
            last_seen = meta.get("state")
            if last_seen == expected_state:
                return True, last_seen
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.2)
    return False, last_seen


if __name__ == "__main__":
    # `--focus` is a flag, not positional -- strip it out of argv wherever it
    # appears so it doesn't shift the positional args below (mirrors
    # verify_session.py's --mic-only handling).
    _argv = sys.argv[1:]
    FOCUS = "--focus" in _argv
    _argv = [a for a in _argv if a != "--focus"]

    if len(_argv) < 1:
        print(__doc__)
        sys.exit(1)

    cmd = _argv[0]

    if cmd == "list":
        title_substr = _argv[1] if len(_argv) > 1 else ""
        if FOCUS:
            activate()
        buttons = parse_buttons(ax_list_buttons(title_substr or None))
        for b in buttons:
            label = b["help"] or b["description"]
            print(f"{b['index']}:{label}")

    elif cmd == "click":
        if len(_argv) < 3:
            print(__doc__)
            sys.exit(1)
        title_substr = _argv[1] or None
        button_arg = _argv[2]
        if FOCUS:
            activate()
        button_index = resolve_button_index(title_substr, button_arg)
        ax_click_button(title_substr, button_index)
        print(f"Clicked button {button_index} ({button_arg})")

        if len(_argv) > 3:
            expected_state = _argv[3]
            # "" (like title_substr's convention) means "auto-detect" -- lets a caller who
            # wants a custom timeout but doesn't know/care about the session_dir write
            # `click ... ended "" 30` instead of having to look up a real path first (a gap
            # hit on 2026-07-03: passing a bare timeout in this slot, e.g. `... ended 90`,
            # silently treated "90" as session_dir and polled a nonexistent path for the
            # entire window, failing with a misleading "last seen: None").
            session_dir_arg = _argv[4] if len(_argv) > 4 else ""
            session_dir = session_dir_arg or find_latest_session()
            timeout_sec = float(_argv[5]) if len(_argv) > 5 else 5.0
            if session_dir is None:
                print(f"ERROR: no sessions found under {SESSIONS_DIR}", file=sys.stderr)
                sys.exit(1)
            if not os.path.isdir(session_dir):
                print(
                    f"ERROR: session_dir {session_dir!r} is not a directory -- did you mean to "
                    f"pass a timeout in this slot? Usage: click <title> <button> <state> "
                    f"[session_dir|\"\"] [timeout_sec]",
                    file=sys.stderr,
                )
                sys.exit(1)
            ok, last_seen = poll_state(session_dir, expected_state, timeout_sec)
            if ok:
                print(f"PASS: meta.json state == {expected_state!r}")
            else:
                print(f"FAIL: meta.json state never reached {expected_state!r} "
                      f"(last seen: {last_seen!r})", file=sys.stderr)
                sys.exit(1)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
