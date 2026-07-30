#!/usr/bin/env python3
"""
Right-click at pixel (px, py) of a Kikimi window's -o capture to open a
SwiftUI `.contextMenu`, then capture the *full screen* (not just the window)
so the resulting NSMenu -- its own WindowServer window, not owned by the
target window's kCGWindowNumber -- actually shows up in the output image.
See kikimi_interact.py's right_click_px() docstring for why a window-scoped
`screencapture -l` would miss the menu.

Non-invasive by default (see click.py) -- pass --focus to fall back to
activate()-first if a background right-click doesn't land.

Usage: right_click.py <window_title_substr> <px> <py> <output.png> [--focus]
       window_title_substr may be "" to match the first Kikimi window found.

After reading the output image to locate a menu item's on-screen position,
click it with click_win.py (or a raw click_px-style CGEventPost) at that
item's actual screen coordinates -- NOT window-relative px/py, since the
menu is not the target window.
"""
import sys
import os
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import right_click_px  # noqa: E402

if __name__ == "__main__":
    argv = [a for a in sys.argv[1:]]
    focus = "--focus" in argv
    argv = [a for a in argv if a != "--focus"]
    if len(argv) != 4:
        print(__doc__)
        sys.exit(1)
    title_substr = argv[0] or None
    px, py, out = float(argv[1]), float(argv[2]), argv[3]
    right_click_px(title_substr, px, py, focus=focus)
    subprocess.run(["screencapture", "-x", out], check=True)
    print(f"Captured to {out}")
