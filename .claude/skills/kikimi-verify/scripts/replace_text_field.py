#!/usr/bin/env python3
"""
Replace the contents of an already-focused-or-focusable text field that has
a *pre-filled* value (e.g. an inline rename field seeded with the current
name), then commit with Return: click at (px, py) of the -o capture to focus
it, Cmd+A to select the existing text, Cmd+V to paste the replacement, then
Return to submit.

This is the pre-filled-field counterpart to type.py (which is for empty
fields you just want to fill once and not submit via Return). Use this one
whenever the field already contains text you need to select-all-and-replace
and then commit (e.g. SettingsView's per-speaker rename TextField).

Non-invasive by default, same posture as click.py/type.py: delivers events
via CGEventPostToPid targeted at Kikimi's process so it reaches the first
responder without requiring Kikimi to be frontmost. In practice, a
just-appeared inline-edit TextField inside a *non-key* window (e.g. Settings
right after opening) may not actually become first responder from a
positional click alone -- if the field still shows the old text after this
script runs, retry with --focus (activates Kikimi first via the global HID
tap), which is what actually made this work when this script was written
(2026-07-07, verifying docs/design/23-speaker-settings-rename.md's Settings
rename UI).

Usage: replace_text_field.py <window_title_substr> <px> <py> <new_text> <output.png> [--focus]
       window_title_substr may be "" to match the first Kikimi window found.
       (px, py) are pixel coordinates in the window's -o capture (same
       convention as click.py) -- read them off a screenshot, not off a
       zoom_crop.py crop (its coordinates are zoomed-local, not full-image;
       convert back with the formula zoom_crop.py prints before passing
       coordinates here).
"""
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import (  # noqa: E402
    get_window, click_px, act_key, act_paste, capture, activate,
    kCGEventFlagMaskCommand,
)

if __name__ == "__main__":
    argv = [a for a in sys.argv[1:]]
    focus = "--focus" in argv
    argv = [a for a in argv if a != "--focus"]
    if len(argv) != 5:
        print(__doc__)
        sys.exit(1)
    title_substr = argv[0] or None
    px, py = float(argv[1]), float(argv[2])
    new_text = argv[3]
    out = argv[4]

    if focus:
        activate()
        time.sleep(0.3)

    click_px(title_substr, px, py, focus=focus)
    time.sleep(0.2)
    act_key(0, kCGEventFlagMaskCommand, title_substr=title_substr, focus=focus)  # Cmd+A
    act_paste(new_text, title_substr=title_substr, focus=focus)
    time.sleep(0.2)
    act_key(36, title_substr=title_substr, focus=focus)  # Return
    time.sleep(0.3)

    w = get_window(title_substr)
    if not w:
        print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
        sys.exit(1)
    capture(w["kCGWindowNumber"], out)
    print(f"Captured to {out}")
