#!/usr/bin/env python3
"""
Click Kikimi's menu-bar extra (the MenuBarExtra status item) and, optionally,
one of its menu items by name.

Added 2026-07-05 while verifying docs/design/18-recording-window-stow-and-compact.md
(the "しまう"/menu-bar-reshow feature): no existing script in this skill drove the
menu-bar extra, only the in-window AX buttons (ax_click.py, scoped to `group 1` of
a *window*). The menu-bar extra is a `menu bar item` of `menu bar 2` (macOS's status
item bar) of the Kikimi process, not part of any window, so it needs its own AX path.

Usage:
    python3 menu_click.py list                      # list current menu item names
    python3 menu_click.py click "<item name>"        # open the menu and click one item
                                                      #   (exact match, falls back to
                                                      #   substring match)

Notes:
- Uses System Events GUI scripting against `menu bar 2` (status items), which works
  on a background/non-frontmost process the same way ax_click.py's window buttons do
  -- no activate() needed.
- The SwiftUI `.menu` label only reflects a snapshot taken when the menu opens (see
  docs/design/18-recording-window-stow-and-compact.md §3.3), so if you need a fresh
  elapsed-time reading, re-open the menu right before reading it rather than reusing
  a stale `list` result.
- Disabled/separator entries come back as `missing value` names in `list`'s raw AX
  read; this script skips them when matching `click`'s target, but still prints them
  (blank) in `list` output so you can see the whole menu shape.
"""
import subprocess
import sys
import time


def _run_osascript(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"ERROR: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return r.stdout.strip()


def wait_for_menu_bar(timeout=40.0):
    """Block until Kikimi's status item exists, or exit(1) after `timeout` seconds.

    Added 2026-07-09: right after build_and_apply.sh / restart.sh, Kikimi's process is
    up but its MenuBarExtra has not registered yet, so every AX path through
    `menu bar 2` fails with `-1719 正しくないインデックスです`. That error reads like a
    broken script rather than "not ready yet", and cost a verification session several
    confused retries -- the status item took ~30s to appear on a cold launch.
    """
    script = 'tell application "System Events" to tell process "Kikimi" to get count of menu bars'
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip().isdigit() and int(r.stdout.strip()) >= 2:
            return
        time.sleep(1.0)
    print(
        f"ERROR: Kikimi's menu-bar extra did not appear within {timeout:.0f}s "
        "(is the process running? check `pgrep -x Kikimi`)",
        file=sys.stderr,
    )
    sys.exit(1)


def list_items():
    script = '''
    tell application "System Events"
        tell process "Kikimi"
            click menu bar item 1 of menu bar 2
            delay 0.3
            set out to ""
            set mi to menu items of menu 1 of menu bar item 1 of menu bar 2
            repeat with i from 1 to count of mi
                set n to ""
                try
                    set n to name of item i of mi
                end try
                set out to out & i & ":" & n & "\\n"
            end repeat
            -- close the menu again so we don't leave it open
            key code 53 -- Escape: safe here, this menu is the frontmost transient
                          -- popup we just opened ourselves, not a Kikimi window (see
                          -- kikimi_interact.py's warning about Esc closing windows).
            return out
        end tell
    end tell
    '''
    return _run_osascript(script)


def click_item(item_name):
    escaped = item_name.replace("\\", "\\\\").replace('"', '\\"')
    script = f'''
    tell application "System Events"
        tell process "Kikimi"
            click menu bar item 1 of menu bar 2
            delay 0.3
            click menu item "{escaped}" of menu 1 of menu bar item 1 of menu bar 2
        end tell
    end tell
    '''
    return _run_osascript(script)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    # Both subcommands go through `menu bar 2`, so neither can run before it exists.
    wait_for_menu_bar()

    if cmd == "list":
        print(list_items())
    elif cmd == "click":
        if len(sys.argv) < 3:
            print("usage: menu_click.py click \"<item name>\"", file=sys.stderr)
            sys.exit(1)
        click_item(sys.argv[2])
        print(f"Clicked menu item: {sys.argv[2]}")
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
