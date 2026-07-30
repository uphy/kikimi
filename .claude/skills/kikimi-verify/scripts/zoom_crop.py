#!/usr/bin/env python3
"""
Crop + zoom a screenshot to help find the exact pixel center of a small,
icon-only control (e.g. a per-row hover button in a LazyVStack list, like
Transcript row's playback button) before clicking it.

Kikimi's per-row buttons (Transcript row playback, speaker-rename triggers,
etc.) have no fixed screen position -- they move with scroll position and
list content, and small icon-only buttons (~20x20pt) are easy to miss by a
few points when guessing coordinates from a full-window screenshot, silently
sending the click to empty space (2026-07-03: `docs/design/15-segment
-playback.md` verification needed 2 tries to hit the button precisely).

They also cannot reliably be found via `ax_click.py`'s AX-tree traversal:
that script only enumerates "group 1" (the header), and a naive "every
button of entire contents of window" walk mixes header buttons, popover
triggers, and per-row buttons in an order that does not match visual
position -- clicking by a guessed index in that flat list can hit the wrong
control entirely (2026-07-03: an index guess landed on "会議終了" instead of
a transcript row's playback button, ending a whole test session by
accident). Prefer this pixel-based approach for any button that lives inside
a scrolling list, not just the fixed header.

Workflow:
    1. Move the mouse over the row (hover) so the button actually renders
       (many of these buttons are `opacity: isHovered ? 1 : 0`).
    2. Screenshot the window region (capture.sh, or `screencapture -R` with
       AppleScript-reported window bounds).
    3. Run this script on a rough crop box around where you expect the
       button (err generous -- e.g. 150x150px) to get a 4x zoomed image.
    4. Read the zoomed image, find the button's center pixel within it,
       convert back to the original screenshot's pixel coordinates, then to
       screen coordinates (bounds.X + px/2, bounds.Y + py/2 for a 2x/Retina,
       no-shadow capture -- see SKILL.md section 4's "キャプチャ座標").

Usage:
    python3 zoom_crop.py <input.png> <left> <top> <right> <bottom> <output.png> [zoom=4]

Requires Pillow (already present in this environment).
"""

import sys

from PIL import Image


def main():
    if len(sys.argv) < 7:
        print(__doc__)
        sys.exit(1)

    input_path = sys.argv[1]
    left, top, right, bottom = (int(v) for v in sys.argv[2:6])
    output_path = sys.argv[6]
    zoom = int(sys.argv[7]) if len(sys.argv) > 7 else 4

    im = Image.open(input_path)
    crop = im.crop((left, top, right, bottom))
    crop = crop.resize((crop.width * zoom, crop.height * zoom))
    crop.save(output_path)
    print(
        f"Saved {output_path} ({crop.width}x{crop.height}, zoom={zoom}x). "
        f"To convert a point (zx, zy) in this image back to the *original* "
        f"screenshot's pixel coordinates: "
        f"orig_x = {left} + zx / {zoom}, orig_y = {top} + zy / {zoom}."
    )


if __name__ == "__main__":
    main()
