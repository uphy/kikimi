#!/usr/bin/env python3
"""Click a pixel position inside a Kikimi window identified by kCGWindowNumber.

Usage: click_win.py <window_number> <pixel_x> <pixel_y> [out.png]

Unlike click.py (which resolves the target window by title substring), this
resolves by the exact kCGWindowNumber from `kikimi_interact.py list`. Use it
when multiple windows share an empty/ambiguous title (e.g. a fresh Draft
window plus a stowed one) and title matching could hit the wrong window.

pixel_x/pixel_y are coordinates in a 2x Retina `screencapture -l <num> -o`
image of that window (same convention as click.py): screen = bounds + px / 2.
Does not activate/focus anything (0 章の非侵襲設計).

Note: the first click on a field inside a fresh nonactivating panel may be
consumed by making the panel key (focus ring appears only after a second
click). Capture and check the focus ring before sending type.py.
"""
import sys
import time

import Quartz


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    win_num = int(sys.argv[1])
    px = float(sys.argv[2])
    py = float(sys.argv[3])
    out = sys.argv[4] if len(sys.argv) > 4 else None

    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID
    )
    bounds = None
    for w in wins:
        if w.get("kCGWindowNumber") == win_num:
            bounds = w["kCGWindowBounds"]
            break
    if bounds is None:
        print(f"ERROR: on-screen window number {win_num} not found")
        return 1

    x = bounds["X"] + px / 2
    y = bounds["Y"] + py / 2
    for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        e = Quartz.CGEventCreateMouseEvent(
            None, event_type, (x, y), Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventSetFlags(e, 0)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
        time.sleep(0.05)
    print(f"clicked window {win_num} at screen ({x}, {y})")

    if out:
        time.sleep(0.4)
        import subprocess

        subprocess.run(["screencapture", "-l", str(win_num), "-o", "-x", out], check=False)
        print(f"Captured to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
