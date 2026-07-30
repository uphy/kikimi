#!/usr/bin/env python3
"""
Scroll inside a Kikimi window's scrollable content, then capture the result.

Added 2026-07-09 while verifying docs/design/28-glossary.md's 用語集 tab: no script
in this skill drove the scroll wheel, so the scroll had to be re-invented as an
inline python one-liner twice in one session.

Scroll position matters, and getting it wrong is destructive:
  - `--at center` (the naive choice) puts the pointer over Settings' Steppers and
    Pickers. A scroll wheel event over an AppKit Stepper/Picker *changes its value*,
    silently editing config.yaml while you think you are only scrolling.
  - `--at left` (the default) parks the pointer in the label gutter, inside the
    ScrollView but clear of every control.
Pass explicit `--px/--py` when neither preset lands where you need it. After scrolling
a form, diff config.yaml against a backup to prove no control absorbed the scroll.

Usage:
    scroll.py <window_title_substr> <direction> [amount] <output.png>
                                          [--at left|center] [--px N --py N]

    direction : up | down          (content direction, as a trackpad user means it)
    amount    : wheel clicks, default 30 (~one screenful of a Settings tab)

Examples:
    scroll.py "設定" down 30 /tmp/out.png            # scroll form to its bottom
    scroll.py "設定" up 20 /tmp/out.png --at center  # scroll a list back to its top
    scroll.py "設定" down 10 /tmp/out.png --px 400 --py 500
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import get_window, capture  # noqa: E402

import Quartz  # noqa: E402
from Quartz import (  # noqa: E402
    CGEventCreateMouseEvent,
    CGEventCreateScrollWheelEvent,
    CGEventPost,
    CGEventSetFlags,
    kCGEventMouseMoved,
    kCGHIDEventTap,
    kCGMouseButtonLeft,
)

STEP = 8  # wheel delta per click; small enough that momentum never overshoots


def _bounds(title_substr):
    w = get_window(title_substr)
    b = w["kCGWindowBounds"]
    return w, b["X"], b["Y"], b["Width"], b["Height"]


def scroll(title_substr, direction, amount, at, px, py):
    w, x, y, width, height = _bounds(title_substr)

    if px is not None and py is not None:
        # Same convention as click.py: pixels of the -o capture (2x Retina).
        sx, sy = x + px / 2, y + py / 2
    elif at == "center":
        sx, sy = x + width / 2, y + height / 2
    else:  # "left": the label gutter -- inside the ScrollView, clear of controls
        sx, sy = x + 40, y + height / 2

    move = CGEventCreateMouseEvent(None, kCGEventMouseMoved, (sx, sy), kCGMouseButtonLeft)
    CGEventSetFlags(move, 0)
    CGEventPost(kCGHIDEventTap, move)
    time.sleep(0.3)

    delta = STEP if direction == "up" else -STEP
    for _ in range(amount):
        e = CGEventCreateScrollWheelEvent(None, 0, 1, delta)
        CGEventPost(kCGHIDEventTap, e)
        time.sleep(0.03)
    time.sleep(0.5)
    return w, sx, sy


if __name__ == "__main__":
    argv = sys.argv[1:]

    at = "left"
    if "--at" in argv:
        i = argv.index("--at")
        at = argv[i + 1]
        del argv[i:i + 2]

    px = py = None
    if "--px" in argv:
        i = argv.index("--px")
        px = float(argv[i + 1])
        del argv[i:i + 2]
    if "--py" in argv:
        i = argv.index("--py")
        py = float(argv[i + 1])
        del argv[i:i + 2]

    if len(argv) == 3:
        title_substr, direction, out = argv
        amount = 30
    elif len(argv) == 4:
        title_substr, direction, amount, out = argv
        amount = int(amount)
    else:
        print(__doc__)
        sys.exit(1)

    if direction not in ("up", "down"):
        print(f"direction must be up|down, got {direction!r}", file=sys.stderr)
        sys.exit(1)

    w, sx, sy = scroll(title_substr or None, direction, amount, at, px, py)
    capture(w["kCGWindowNumber"], out)
    print(f"Scrolled {direction} x{amount} at ({sx:.0f}, {sy:.0f}); captured to {out}")
