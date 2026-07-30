#!/usr/bin/env python3
"""
Kikimi GUI interaction helper (modeled after chirami-verify's chirami_interact.py).

Kikimi windows have dynamic titles (meeting title), unlike Chirami's fixed
"Test" note, so window lookup here is by owner name ("Kikimi") and optionally
by title substring. Recording is not driven by a global hotkey in the MVP;
use the `kikimi://` URL scheme (open_url) or on-screen buttons via click_px.

Usage:
    python3 kikimi_interact.py list                              # list all Kikimi windows
    python3 kikimi_interact.py open_url "kikimi://window/new"    # open a new Draft window
    python3 kikimi_interact.py capture <window_title_substr> <output.png>
    python3 kikimi_interact.py click <window_title_substr> <px> <py> <output.png>
    python3 kikimi_interact.py cmd_click <window_title_substr> <px> <py> <output.png>
    python3 kikimi_interact.py double_click <window_title_substr> <px> <py> <output.png>
    python3 kikimi_interact.py right_click <window_title_substr> <px> <py> <output.png>
        # NOTE: <output.png> is a full-screen capture (screencapture -x), not
        # a window-scoped one -- see right_click_px()'s docstring for why.
    python3 kikimi_interact.py paste <window_title_substr> <text>

Captures use `screencapture -o` (no shadow) => image is bounds x 2x, so
pixel (px, py) maps to screen point (bounds.X + px/2, bounds.Y + py/2).

NOTE: never send a bare Escape as a generic "dismiss" -- Esc can close the
active window, and a follow-up Esc can leak to the app behind it (can
interrupt your session).

--- Non-invasive by design (2026-07-05) ---

Kikimi's windows are AppKit `.nonactivatingPanel`s (see
Kikimi/Window/FloatingPanel.swift): by design they accept mouse clicks and
become the app's key window WITHOUT bringing the Kikimi *process* frontmost.
Verified empirically (frontmost app checked before/after via System Events):
  - Positional mouse clicks (CGEventPost at the panel's actual screen
    coordinates) reach the panel and are handled normally with no prior
    activate() -- the WindowServer routes by screen position, not by which
    app is frontmost.
  - AX actions via System Events ("click button ... of process Kikimi") work
    on a background (non-frontmost) process as-is; GUI scripting does not
    require the target to be frontmost, only that it's running and
    Accessibility access is granted.
  - Keyboard input (e.g. Cmd+V paste) is different: a plain
    `CGEventPost(kCGHIDEventTap, ...)` targets whatever process the system
    currently considers active, so it can leak to the real frontmost app
    instead of Kikimi. Use `CGEventPostToPid(pid, ...)` (this module's
    default for keyboard events) to target Kikimi's process specifically --
    this reaches the window's current first responder (so click into the
    target field first) without touching frontmost-ness at all.
  - `open`ing the `kikimi://` scheme or the app bundle activates the target
    by default; pass `-g` to suppress that (this module's open_url() does
    this automatically).

Because of this, every action function below defaults to NOT calling
activate() and NOT stealing focus/frontmost/mouse-cursor position. Pass
`focus=True` (or the CLI's `--focus` flag) to fall back to the old
activate() + global-HID-tap behavior for the rare case a non-invasive path
doesn't reach Kikimi (e.g. an unusual window-manager setup). When adding new
scripts, follow the same default: don't reach for activate() "just in case"
-- prove it's needed first (see this module's history for the empirical
test method: check `frontmost_app()` before/after).
"""

import sys
import time
import subprocess
import Quartz
from Quartz import (
    CGEventCreateKeyboardEvent,
    CGEventCreateMouseEvent,
    CGEventPost,
    CGEventPostToPid,
    CGEventSetFlags,
    CGEventSetIntegerValueField,
    CGWindowListCopyWindowInfo,
    CGRectMake,
    kCGHIDEventTap,
    kCGWindowListOptionAll,
    kCGWindowListOptionOnScreenOnly,
    kCGNullWindowID,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventRightMouseDown,
    kCGEventRightMouseUp,
    kCGMouseButtonLeft,
    kCGMouseButtonRight,
    kCGEventFlagMaskCommand,
    kCGMouseEventClickState,
)

OWNER_NAME = "Kikimi"


def post_key(key_code, flags=0, pid=None):
    """Post a keydown/keyup pair. When `pid` is given, deliver via
    CGEventPostToPid (targets that process's current first responder
    directly, regardless of which app is frontmost -- click into the target
    field first so it actually has focus). When `pid` is None, falls back to
    the global HID tap, which targets whatever the system currently
    considers the active app -- only correct if that app is Kikimi (i.e.
    after a real activate())."""
    for down in (True, False):
        e = CGEventCreateKeyboardEvent(None, key_code, down)
        CGEventSetFlags(e, flags)
        if pid is not None:
            CGEventPostToPid(pid, e)
        else:
            CGEventPost(kCGHIDEventTap, e)
    time.sleep(0.05)


def post_click(x, y, flags=0, click_state=1):
    """Post one mouse-down/up pair at (x, y). `flags` is a CGEventFlags mask
    (e.g. kCGEventFlagMaskCommand for a Command-click, used to test List
    multi-select toggle). `click_state` is AppKit's click count field
    (kCGMouseEventClickState) -- set to 2 on a *second* post_click call made
    shortly after a click_state=1 call at the same point to make AppKit
    register a real double-click (NSEvent.clickCount == 2), which is what
    `.contextMenu(forSelectionType:primaryAction:)`'s primaryAction and
    old-style row TapGesture(count: 2) both key off of. Two independent
    click_state=1 clicks are seen by AppKit as two separate single clicks,
    not a double-click, no matter how fast they're posted."""
    pt = (x, y)
    for etype in (kCGEventLeftMouseDown, kCGEventLeftMouseUp):
        e = CGEventCreateMouseEvent(None, etype, pt, kCGMouseButtonLeft)
        CGEventSetFlags(e, flags)
        CGEventSetIntegerValueField(e, kCGMouseEventClickState, click_state)
        CGEventPost(kCGHIDEventTap, e)
    time.sleep(0.05)


def post_right_click(x, y):
    """Post one right-mouse-down/up pair at (x, y) -- opens a SwiftUI
    `.contextMenu`. Unlike `post_click`, there is no click-count field to
    juggle: a single right-mouse-down/up pair is what AppKit expects to open
    a context menu."""
    pt = (x, y)
    for etype in (kCGEventRightMouseDown, kCGEventRightMouseUp):
        e = CGEventCreateMouseEvent(None, etype, pt, kCGMouseButtonRight)
        CGEventSetFlags(e, 0)
        CGEventPost(kCGHIDEventTap, e)
    time.sleep(0.05)


def list_windows(on_screen_only=False):
    """List all windows owned by Kikimi. Menu bar apps have no Dock icon, so
    use kCGWindowListOptionOnScreenOnly to check real visible state."""
    option = kCGWindowListOptionOnScreenOnly if on_screen_only else kCGWindowListOptionAll
    windows = CGWindowListCopyWindowInfo(option, kCGNullWindowID)
    return [w for w in windows if OWNER_NAME in str(w.get("kCGWindowOwnerName", ""))]


def get_window(title_substr=None, on_screen_only=False):
    """Return the first Kikimi window whose title contains title_substr
    (or the first Kikimi window at all if title_substr is None)."""
    for w in list_windows(on_screen_only=on_screen_only):
        name = str(w.get("kCGWindowName", ""))
        if title_substr is None or title_substr in name:
            return w
    return None


def window_center(w):
    b = w["kCGWindowBounds"]
    return int(b["X"]) + int(b["Width"]) // 2, int(b["Y"]) + int(b["Height"]) // 2


def capture(window_id, output_path):
    # -o drops the window's drop shadow, so the image is exactly bounds x 2x
    # (Retina). That makes pixel->screen mapping trivial:
    #   screen_x = bounds["X"] + pixel_x / 2
    #   screen_y = bounds["Y"] + pixel_y / 2
    subprocess.run(["screencapture", "-l", str(window_id), "-o", output_path], check=True)


def set_clipboard(text):
    subprocess.run(["pbcopy"], input=text.encode(), check=True)


def open_url(url):
    """Drive Kikimi via its kikimi:// URL scheme (e.g. window/new, record/quick).
    Uses `open -g` so the target app is NOT brought frontmost by the open(1)
    call itself (verified: the resulting window appears on-screen with
    frontmost unchanged)."""
    subprocess.run(["open", "-g", url], check=True)


# --- Focus & activation ---
#
# Kikimi has no global hotkey in the MVP (kikimi.md explicitly defers this),
# so window show/hide is driven by kikimi:// URLs or on-screen buttons.
# activate() below is now only used as the `focus=True`/`--focus` fallback --
# the default (non-invasive) action functions further down don't call it (see
# the module docstring's "Non-invasive by design" section).


def activate():
    """Bring Kikimi frontmost. Non-blocking; pair with a short sleep then act
    immediately (before the terminal reclaims focus)."""
    subprocess.Popen(["osascript", "-e", 'tell application "Kikimi" to activate'])
    time.sleep(0.18)


def frontmost_app():
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get name of first process whose frontmost is true'],
        capture_output=True, text=True)
    return r.stdout.strip()


def move_mouse(x, y):
    from Quartz import CGEventCreateMouseEvent as _mk, kCGEventMouseMoved
    e = _mk(None, kCGEventMouseMoved, (x, y), kCGMouseButtonLeft)
    CGEventSetFlags(e, 0)
    CGEventPost(kCGHIDEventTap, e)
    time.sleep(0.08)


# --- Non-invasive by default; `focus=True` restores the old activate()-first
#     behavior as a fallback for the rare case a background action doesn't
#     reach Kikimi (see the module docstring for what was verified and why).

def act_key(key_code, flags=0, title_substr=None, focus=False):
    """Post a Cmd+V-style key combo. When focus is False (default), targets
    Kikimi's process directly via CGEventPostToPid (looked up from the
    window matching title_substr) so the event reaches Kikimi's current
    first responder without requiring Kikimi to be frontmost -- click into
    the target field first so it actually has focus. When focus is True,
    activates Kikimi first and posts via the global HID tap instead (the
    old behavior)."""
    if focus:
        activate()
        post_key(key_code, flags)
    else:
        w = get_window(title_substr)
        if not w:
            print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
            sys.exit(1)
        post_key(key_code, flags, pid=w["kCGWindowOwnerPID"])
    time.sleep(0.2)


def act_paste(text, title_substr=None, focus=False):
    set_clipboard(text)
    act_key(9, kCGEventFlagMaskCommand, title_substr=title_substr, focus=focus)  # Cmd+V


def click_px(title_substr, px, py, flags=0, focus=False):
    """Click at pixel (px, py) of the -o capture of the named window.
    The capture is bounds x 2x, so divide by 2 to get screen points.
    `flags` is a CGEventFlags mask; pass kCGEventFlagMaskCommand for a
    Command-click (List multi-select toggle) or kCGEventFlagMaskShift for a
    Shift-click (List multi-select range).

    Mouse clicks are positional -- the WindowServer delivers them to
    whichever window is on screen at that point, regardless of which app is
    frontmost -- so this does NOT call activate() by default (verified: a
    background click reaches Kikimi's nonactivating panel and frontmost
    stays unchanged). Pass focus=True to restore the old activate()-first
    behavior if a background click doesn't land in some environment."""
    if focus:
        activate()
    w = get_window(title_substr)
    if not w:
        print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
        sys.exit(1)
    b = w["kCGWindowBounds"]
    x = b["X"] + px / 2
    y = b["Y"] + py / 2
    move_mouse(x, y)
    post_click(x, y, flags=flags)
    time.sleep(0.4)
    return w


def right_click_px(title_substr, px, py, focus=False):
    """Right-click at pixel (px, py) of the -o capture of the named window to
    open a SwiftUI `.contextMenu`. Non-invasive by default, same as
    `click_px`.

    IMPORTANT: the resulting NSMenu is its own WindowServer window (not owned
    by the target window's `kCGWindowNumber`), so `capture(w
    ["kCGWindowNumber"], ...)` will NOT show it -- take a full-screen
    `screencapture` (no `-l`) instead, e.g.
    `subprocess.run(["screencapture", "-x", out])`, then locate/crop the menu
    in that image. Returns the window dict (same shape as `click_px`) so the
    caller can still compute `bounds.X/Y` for translating menu-item
    coordinates back to CGEventPost screen points."""
    if focus:
        activate()
    w = get_window(title_substr)
    if not w:
        print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
        sys.exit(1)
    b = w["kCGWindowBounds"]
    x = b["X"] + px / 2
    y = b["Y"] + py / 2
    move_mouse(x, y)
    post_right_click(x, y)
    time.sleep(0.4)
    return w


def double_click_px(title_substr, px, py, focus=False):
    """Double-click at pixel (px, py) of the -o capture of the named window.
    Posts two click_px-equivalent click pairs with AppKit's click-count field
    (kCGMouseEventClickState) set to 1 then 2, which is what actually makes
    AppKit recognize the pair as a double-click (NSEvent.clickCount == 2) --
    see `.contextMenu(forSelectionType:primaryAction:)` in SessionListView.
    Use this instead of two independent click_px calls, which register as
    two single clicks no matter how close together they're posted.

    Non-invasive by default (see click_px) -- pass focus=True to fall back
    to activate()-first."""
    if focus:
        activate()
    w = get_window(title_substr)
    if not w:
        print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
        sys.exit(1)
    b = w["kCGWindowBounds"]
    x = b["X"] + px / 2
    y = b["Y"] + py / 2
    move_mouse(x, y)
    post_click(x, y, click_state=1)
    time.sleep(0.08)
    post_click(x, y, click_state=2)
    time.sleep(0.4)
    return w


# --- AX (Accessibility) fallback ---
#
# Prefer this over click_px for header buttons: it targets a button by NAME
# (its AX `help` label) rather than by pixel position, so it doesn't drift
# when the header's button layout changes with session state. System Events
# GUI scripting (used here) works on a background/non-frontmost process as-is
# -- no activate() needed (verified 2026-07-05: clicking a header button via
# System Events with Kikimi non-frontmost fired correctly and left frontmost
# unchanged) -- but target the window by TITLE, not by index ("window
# 1"/"window 2"): System Events' window ordering does not reliably match
# CGWindowList's, so index-based targeting has been observed to silently
# click the wrong window or throw -1719 "invalid index" (2026-07-03). Known
# gap: popovers on a nonactivating panel (e.g. the speaker-rename popover) do
# not appear in the AX tree at all -- there is no AX-based click for those;
# verify that flow by inspecting the resulting state file (e.g.
# voiceprints.json) instead of by clicking.


def ax_window_ref(title_substr):
    """AppleScript expression selecting the target window. Falls back to
    "window 1" only when no title is given (single-window case); prefer
    always passing a title_substr when more than one Kikimi window may be
    open."""
    if not title_substr:
        return "window 1"
    escaped = title_substr.replace("\\", "\\\\").replace('"', '\\"')
    return f'(first window whose name contains "{escaped}")'


def _run_osascript(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"ERROR: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return r.stdout.strip()


def ax_list_buttons(title_substr):
    """List the buttons in group 1 (the header) of the matched window, as raw
    "index:name|description|help" lines (one field may be the literal string
    "missing value" if AppleScript couldn't read that property -- callers
    should treat that as empty). `help` is the AX `help` property, which
    Kikimi now sets to a fixed Japanese label per button (see SKILL.md's
    button-label contract table) -- prefer it over `name`/`description` for
    identifying a button, since header button *position* shifts with session
    state and with the title-proposal badge but the label contract does not.
    ax_click.py's `resolve_button_index` parses this output to support
    clicking by name."""
    win_ref = ax_window_ref(title_substr)
    script = f'''
    tell application "System Events"
        tell process "Kikimi"
            set w to {win_ref}
            set out to ""
            set btns to buttons of group 1 of w
            repeat with i from 1 to count of btns
                set b to item i of btns
                set n to ""
                set d to ""
                set h to ""
                try
                    set n to name of b
                end try
                try
                    set d to description of b
                end try
                try
                    set h to help of b
                end try
                set out to out & i & ":" & n & "|" & d & "|" & h & "\\n"
            end repeat
            return out
        end tell
    end tell
    '''
    return _run_osascript(script)


def ax_click_button(title_substr, button_index):
    """Click the Nth (1-based) button in group 1 of the window matched by
    TITLE (not index -- see module docstring above)."""
    win_ref = ax_window_ref(title_substr)
    script = f'''
    tell application "System Events"
        tell process "Kikimi"
            set w to {win_ref}
            click button {button_index} of group 1 of w
        end tell
    end tell
    '''
    _run_osascript(script)


if __name__ == "__main__":
    # `--focus` is a flag, not positional -- strip it out of argv wherever it
    # appears so it doesn't shift the positional args below (mirrors
    # verify_session.py's --mic-only handling).
    _argv = sys.argv[1:]
    FOCUS = "--focus" in _argv
    _argv = [a for a in _argv if a != "--focus"]

    if len(_argv) < 1:
        print(__doc__)
        sys.exit(1)

    cmd = _argv[0]

    if cmd == "list":
        for w in list_windows():
            print(f"{w.get('kCGWindowNumber')}\t{w.get('kCGWindowName')}\t"
                  f"onScreen={w in list_windows(on_screen_only=True)}")

    elif cmd == "open_url":
        open_url(_argv[1])

    elif cmd == "capture":
        title_substr, out = _argv[1], _argv[2]
        w = get_window(title_substr if title_substr else None)
        if not w:
            print(f"ERROR: window matching '{title_substr}' not found", file=sys.stderr)
            sys.exit(1)
        capture(w["kCGWindowNumber"], out)
        print(f"Captured to {out}")

    elif cmd == "click":
        title_substr, px, py, out = _argv[1], float(_argv[2]), float(_argv[3]), _argv[4]
        w = click_px(title_substr if title_substr else None, px, py, focus=FOCUS)
        capture(w["kCGWindowNumber"], out)
        print(f"Captured to {out}")

    elif cmd == "cmd_click":
        title_substr, px, py, out = _argv[1], float(_argv[2]), float(_argv[3]), _argv[4]
        w = click_px(title_substr if title_substr else None, px, py, flags=kCGEventFlagMaskCommand, focus=FOCUS)
        capture(w["kCGWindowNumber"], out)
        print(f"Captured to {out}")

    elif cmd == "double_click":
        title_substr, px, py, out = _argv[1], float(_argv[2]), float(_argv[3]), _argv[4]
        w = double_click_px(title_substr if title_substr else None, px, py, focus=FOCUS)
        capture(w["kCGWindowNumber"], out)
        print(f"Captured to {out}")

    elif cmd == "right_click":
        title_substr, px, py, out = _argv[1], float(_argv[2]), float(_argv[3]), _argv[4]
        right_click_px(title_substr if title_substr else None, px, py, focus=FOCUS)
        # Full-screen capture, not window-scoped -- see right_click_px()'s docstring.
        subprocess.run(["screencapture", "-x", out], check=True)
        print(f"Captured to {out}")

    elif cmd == "paste":
        title_substr, text = _argv[1], _argv[2].replace("\\n", "\n")
        act_paste(text, title_substr=title_substr if title_substr else None, focus=FOCUS)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
