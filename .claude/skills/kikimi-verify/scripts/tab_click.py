#!/usr/bin/env python3
"""Switch the Session Window's tab (準備 / 会議 / Watchers / チャット) over AX.

WHY THIS EXISTS
`ax_click.py` only walks the header's `group 1`, and the tab bar is not there. It also does not
appear as an AXTabGroup, which is why an earlier search for one came up empty. The tab bar actually
lives at:

    window 1 > toolbar 1 > group 1 > radio group 1 ("Navigation Tab Bar")

and its tabs are radio buttons whose *description* carries the label (`name`/`title` are all
`missing value`). Verified 2026-07-30, including under `KIKIMI_TEST_HIDDEN=1` where the window is
fully transparent -- AX does not care about alpha, so this works when coordinate clicks cannot.

This is the missing piece for verifying WebView-rendered surfaces (`webview.sh`): the summary,
Watchers and chat pages only exist once their tab has been opened.

Usage:
    tab_click.py list                 # print the tab labels in order
    tab_click.py click チャット        # open a tab by label (exact match)
    tab_click.py click 会議 --window "会議タイトル"   # disambiguate by window title

Exit status: 0 on success, 1 when the tab (or the window) could not be found.
"""

import subprocess
import sys

TAB_BAR = "toolbar 1 of window {win} of process \"Kikimi\""


def run_osascript(script: str) -> tuple[int, str]:
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    return result.returncode, (result.stdout or result.stderr).strip()


def window_clause(title: str | None) -> str:
    """Targets window 1 by default; `kikimi-verify` normally drives a single Session Window."""
    if not title:
        return "window 1"
    # `whose title contains` mirrors the partial matching the other scripts use.
    return f'(first window whose title contains "{title}")'


def tab_bar_clause(title: str | None) -> str:
    return f"radio group 1 of group 1 of toolbar 1 of {window_clause(title)}"


def list_tabs(title: str | None) -> int:
    code, out = run_osascript(
        f'tell application "System Events" to tell process "Kikimi" '
        f"to get description of every radio button of {tab_bar_clause(title)}"
    )
    if code != 0:
        print(f"failed to read the tab bar: {out}", file=sys.stderr)
        print(
            "Is a Session Window open? A Draft window has no tab bar (design 17 §3.1).",
            file=sys.stderr,
        )
        return 1
    labels = [part.strip() for part in out.split(",")]
    # The radio group reports a leading run of `missing value` entries (the segmented control's own
    # internal elements); only the labelled ones are real tabs.
    for index, label in enumerate(labels, start=1):
        if label and label != "missing value":
            print(f"{index}:{label}")
    return 0


def click_tab(label: str, title: str | None) -> int:
    code, out = run_osascript(
        f'tell application "System Events" to tell process "Kikimi" '
        f"to click (first radio button of {tab_bar_clause(title)} whose description is \"{label}\")"
    )
    if code != 0:
        print(f"failed to click tab {label!r}: {out}", file=sys.stderr)
        return 1
    print(f"clicked tab: {label}")
    return 0


def main(argv: list[str]) -> int:
    window_title = None
    if "--window" in argv:
        i = argv.index("--window")
        if i + 1 >= len(argv):
            print("--window needs a value", file=sys.stderr)
            return 2
        window_title = argv[i + 1]
        del argv[i : i + 2]

    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    action = argv[1]
    if action == "list":
        return list_tabs(window_title)
    if action == "click":
        if len(argv) < 3:
            print("usage: tab_click.py click <label>", file=sys.stderr)
            return 2
        return click_tab(argv[2], window_title)

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
