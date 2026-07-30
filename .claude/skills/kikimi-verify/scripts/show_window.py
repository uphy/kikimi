#!/usr/bin/env python3
"""
Patch ~/.local/state/kikimi/state.yaml to make a session's window visible
without launching Kikimi and clicking through the UI to find it -- useful to
reopen an EXISTING session (Draft/Paused/Ended) at a known, deterministic
window for capture/click scripts to target by title, or to declutter the
screen before a capture.

Kikimi only reads state.yaml at launch and only writes it while running (see
Kikimi/Config/AppState.swift), so this script REFUSES to run while Kikimi is
running -- Kikimi would silently overwrite this edit with its in-memory state
on its next save (e.g. on quit), making the edit look like it "didn't stick".
Quit Kikimi first (or don't launch it yet), run this script, then launch.

This intentionally does not depend on PyYAML (not guaranteed to be
installed) -- state.yaml's shape is simple and stable enough (a top-level
`windows:` block sequence of flat mappings, plus a `session_list_window:`
mapping, both written by Yams -- see kikimi.md 12 章) that regex/line-based
patching is reliable and, critically, leaves every untouched line (including
Yams' `1.12e+3`-style float formatting) byte-for-byte unchanged.

Usage:
    show_window.py <session-id> [--hide-others] [--hide-session-list] [--state-file PATH]

    <session-id>          Session folder name under ~/.local/state/kikimi/sessions/.
                           If it has no entry yet in state.yaml, one is added
                           with default geometry (x=100, y=100, width=800,
                           height=600, active_tab=prep) and visible: true.
                           If it already has an entry, only `visible` is
                           flipped to true (existing geometry/tab untouched).
    --hide-others          Set visible: false on every OTHER window entry.
    --hide-session-list    Set visible: false on the session_list_window entry.
    --state-file PATH      Operate on PATH instead of the real state.yaml
                           (for testing against a copy; skips the
                           Kikimi-must-not-be-running check).

Prints a summary of what changed. Exits 1 on refusal or if the session-id
looks malformed.
"""
import sys
import os
import re
import subprocess

DEFAULT_STATE_FILE = os.path.expanduser("~/.local/state/kikimi/state.yaml")

TOP_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")
LIST_ITEM_RE = re.compile(r"^- session_id:\s*(.+)\s*$")

DEFAULT_WINDOW_BLOCK = """- session_id: {session_id}
  x: 100
  y: 100
  width: 800
  height: 600
  visible: true
  active_tab: prep
"""


def kikimi_is_running():
    """True if a Kikimi process is currently running (pgrep by exact name,
    matching the executable name inside Kikimi.app/Contents/MacOS/Kikimi)."""
    result = subprocess.run(["pgrep", "-x", "Kikimi"], capture_output=True, text=True)
    return result.returncode == 0


def find_section_bounds(lines, key):
    """Return (start, end) line-index bounds (start inclusive of the first
    value line, end exclusive) for the block following a top-level `key:`
    line. `end` is the index of the next top-level key line, or len(lines)
    if `key` is the last section. Returns (None, None) if `key:` isn't
    found as a top-level line."""
    start = None
    for i, line in enumerate(lines):
        m = TOP_KEY_RE.match(line)
        if not m:
            continue
        if start is None and m.group(1) == key:
            start = i + 1
            continue
        if start is not None:
            return start, i
    if start is not None:
        return start, len(lines)
    return None, None


def find_window_blocks(lines, start, end):
    """Within lines[start:end] (the `windows:` section), return a list of
    (block_start, block_end, session_id) for each `- session_id: ...` list
    item. block_end is exclusive (start of next item or `end`)."""
    items = []
    cur_start = None
    cur_id = None
    for i in range(start, end):
        m = LIST_ITEM_RE.match(lines[i])
        if m:
            if cur_start is not None:
                items.append((cur_start, i, cur_id))
            cur_start = i
            cur_id = m.group(1)
    if cur_start is not None:
        items.append((cur_start, end, cur_id))
    return items


def set_visible_in_block(lines, block_start, block_end, want_visible):
    """Set the `visible:` field within lines[block_start:block_end] (a
    window or session_list_window block) to want_visible. Returns True if a
    `visible:` line was found and changed (or already matched), False if no
    such line existed in the block (caller's responsibility to handle)."""
    value = "true" if want_visible else "false"
    changed = False
    for i in range(block_start, block_end):
        m = re.match(r"^(\s*)visible:\s*(\S+)\s*$", lines[i])
        if m:
            indent, current = m.group(1), m.group(2)
            if current != value:
                lines[i] = f"{indent}visible: {value}"
                changed = True
            return True, changed
    return False, changed


def main(argv):
    if len(argv) < 1 or argv[0].startswith("-"):
        print(__doc__)
        return 1

    session_id = argv[0]
    hide_others = "--hide-others" in argv[1:]
    hide_session_list = "--hide-session-list" in argv[1:]
    state_file = DEFAULT_STATE_FILE
    is_override = False
    if "--state-file" in argv[1:]:
        idx = argv.index("--state-file")
        if idx + 1 >= len(argv):
            print("ERROR: --state-file requires a PATH argument", file=sys.stderr)
            return 1
        state_file = argv[idx + 1]
        is_override = True

    if not is_override and kikimi_is_running():
        print("ERROR: Kikimi is currently running. Quit it first -- Kikimi only "
              "writes state.yaml from its own in-memory state, so it would "
              "overwrite this edit (e.g. on quit) and the change would appear "
              "to silently revert.", file=sys.stderr)
        return 1

    if not os.path.isfile(state_file):
        print(f"ERROR: state file not found: {state_file}", file=sys.stderr)
        return 1

    with open(state_file, encoding="utf-8") as f:
        text = f.read()
    had_trailing_newline = text.endswith("\n")
    lines = text.splitlines()

    messages = []

    windows_start, windows_end = find_section_bounds(lines, "windows")
    if windows_start is None:
        # No top-level `windows:` key at all -- extremely unlikely (AppState
        # always serializes it, even as `windows: []`), but degrade cleanly
        # by creating the section at the top of the file.
        lines = ["windows:"] + lines
        windows_start, windows_end = 1, 1
    elif windows_start < len(lines) and lines[windows_start - 1].strip() in ("windows: []", "windows: {}"):
        # Flow-style empty list -- normalize to a bare `windows:` key so a
        # block sequence item can be appended under it.
        lines[windows_start - 1] = "windows:"
        windows_end = windows_start

    blocks = find_window_blocks(lines, windows_start, windows_end)
    target_block = next((b for b in blocks if b[2] == session_id), None)

    if target_block is not None:
        b_start, b_end, _ = target_block
        found, changed = set_visible_in_block(lines, b_start, b_end, True)
        if not found:
            # Shouldn't happen (Codable always serializes `visible`), but
            # don't silently no-op if it does.
            lines.insert(b_end, "  visible: true")
            changed = True
        messages.append(
            f"Set window '{session_id}' visible=true (existing entry)"
            if changed else f"Window '{session_id}' was already visible=true (existing entry)"
        )
    else:
        new_block_lines = DEFAULT_WINDOW_BLOCK.format(session_id=session_id).splitlines()
        # Recompute windows_end in case earlier normalization shifted it.
        windows_start, windows_end = find_section_bounds(lines, "windows")
        lines[windows_end:windows_end] = new_block_lines
        # Blocks below windows_end shift down by len(new_block_lines); redo
        # the block scan for any later --hide-others pass.
        windows_start, windows_end = find_section_bounds(lines, "windows")
        blocks = find_window_blocks(lines, windows_start, windows_end)
        messages.append(f"Added window entry for '{session_id}' with default geometry (visible=true)")

    if hide_others:
        hidden = 0
        for b_start, b_end, sid in blocks:
            if sid == session_id:
                continue
            _, changed = set_visible_in_block(lines, b_start, b_end, False)
            if changed:
                hidden += 1
        messages.append(f"Hid {hidden} other window(s)" if hidden else "No other windows needed hiding")

    if hide_session_list:
        sl_start, sl_end = find_section_bounds(lines, "session_list_window")
        if sl_start is None:
            messages.append("No session_list_window section found -- nothing to hide")
        else:
            found, changed = set_visible_in_block(lines, sl_start, sl_end, False)
            if not found:
                lines.insert(sl_end, "  visible: false")
                changed = True
            messages.append("Hid session_list_window" if changed else "session_list_window was already hidden")

    new_text = "\n".join(lines) + ("\n" if had_trailing_newline else "")
    with open(state_file, "w", encoding="utf-8") as f:
        f.write(new_text)

    for m in messages:
        print(m)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
