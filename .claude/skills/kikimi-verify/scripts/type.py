#!/usr/bin/env python3
"""
Type (paste) text into the currently focused field of a Kikimi window via
Cmd+V, then capture the result. Click into the target field first (e.g. with
click.py) so it actually has keyboard focus -- this script does not click
anywhere itself.

Non-invasive by default: delivers Cmd+V via CGEventPostToPid targeted at
Kikimi's process, so it reaches Kikimi's first responder without requiring
Kikimi to be frontmost (verified 2026-07-05: pasted text landed correctly
with frontmost unchanged throughout). Pass --focus to fall back to the old
activate() + global-HID-tap behavior if this doesn't reach Kikimi in some
environment.

Usage: type.py <window_title_substr> <text> <output.png> [--focus]
       window_title_substr may be "" to match the first Kikimi window found.
       Use "\\n" in <text> for newlines.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import get_window, act_paste, capture  # noqa: E402

if __name__ == "__main__":
    argv = [a for a in sys.argv[1:]]
    focus = "--focus" in argv
    argv = [a for a in argv if a != "--focus"]
    if len(argv) != 3:
        print(__doc__)
        sys.exit(1)
    title_substr = argv[0] or None
    text = argv[1].replace("\\n", "\n")
    out = argv[2]

    act_paste(text, title_substr=title_substr, focus=focus)

    w = get_window(title_substr)
    if not w:
        print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
        sys.exit(1)
    capture(w["kCGWindowNumber"], out)
    print(f"Captured to {out}")
