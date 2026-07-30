#!/usr/bin/env python3
"""
Command-click at pixel (px, py) of a Kikimi window's -o capture, then
capture the result. Use this to verify `List(selection: Set<...>)` toggle
multi-select (Command-click adds/removes the clicked row from the
selection) without disturbing the rest of the selection, e.g. in
SessionListView's session list.

Non-invasive by default: does NOT activate/frontmost Kikimi (see click.py).
Pass --focus to fall back to the old activate()-first behavior.

Usage: cmd_click.py <window_title_substr> <px> <py> <output.png> [--focus]
       window_title_substr may be "" to match the first Kikimi window found.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import click_px, capture, kCGEventFlagMaskCommand  # noqa: E402

if __name__ == "__main__":
    argv = [a for a in sys.argv[1:]]
    focus = "--focus" in argv
    argv = [a for a in argv if a != "--focus"]
    if len(argv) != 4:
        print(__doc__)
        sys.exit(1)
    title_substr = argv[0] or None
    px, py, out = float(argv[1]), float(argv[2]), argv[3]
    w = click_px(title_substr, px, py, flags=kCGEventFlagMaskCommand, focus=focus)
    capture(w["kCGWindowNumber"], out)
    print(f"Captured to {out}")
