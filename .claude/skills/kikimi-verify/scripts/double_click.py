#!/usr/bin/env python3
"""
Double-click at pixel (px, py) of a Kikimi window's -o capture, then capture
the result. Unlike two independent click.py calls (which AppKit sees as two
separate single clicks no matter how fast they're posted), this sets
AppKit's click-count field (kCGMouseEventClickState) to 1 then 2 so the pair
is recognized as a real double-click (NSEvent.clickCount == 2) -- see
kikimi_interact.double_click_px. Use this to verify List rows that open on
double-click via `.contextMenu(forSelectionType:primaryAction:)`
(SessionListView's "開く" flow).

Non-invasive by default: does NOT activate/frontmost Kikimi (see click.py).
Pass --focus to fall back to the old activate()-first behavior.

Usage: double_click.py <window_title_substr> <px> <py> <output.png> [--focus]
       window_title_substr may be "" to match the first Kikimi window found.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import double_click_px, capture  # noqa: E402

if __name__ == "__main__":
    argv = [a for a in sys.argv[1:]]
    focus = "--focus" in argv
    argv = [a for a in argv if a != "--focus"]
    if len(argv) != 4:
        print(__doc__)
        sys.exit(1)
    title_substr = argv[0] or None
    px, py, out = float(argv[1]), float(argv[2]), argv[3]
    w = double_click_px(title_substr, px, py, focus=focus)
    capture(w["kCGWindowNumber"], out)
    print(f"Captured to {out}")
