#!/usr/bin/env python3
"""
Check whether Kikimi is running and whether a window is actually visible
on-screen. Kikimi is a menu-bar (LSUIElement) app with no Dock icon, so
process-alive alone does not tell you whether a given window is showing --
use kCGWindowListOptionOnScreenOnly for the real visible state.

Usage: check_visible.py [window_title_substr]
       With no argument, reports process status and lists all on-screen
       Kikimi windows. With an argument, exits 0 if a window whose title
       contains the substring is on-screen, exits 1 otherwise.
"""
import sys
import os
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kikimi_interact import list_windows  # noqa: E402


def is_process_running():
    r = subprocess.run(["pgrep", "-x", "Kikimi"], capture_output=True)
    return r.returncode == 0


if __name__ == "__main__":
    running = is_process_running()
    print(f"process running: {running}")

    on_screen = list_windows(on_screen_only=True)
    print(f"on-screen Kikimi windows: {len(on_screen)}")
    for w in on_screen:
        print(f"  - \"{w.get('kCGWindowName')}\" (id={w.get('kCGWindowNumber')})")

    if len(sys.argv) > 1:
        title_substr = sys.argv[1]
        match = any(title_substr in str(w.get("kCGWindowName", "")) for w in on_screen)
        sys.exit(0 if match else 1)
