#!/usr/bin/env bash
# Read and click inside Kikimi's WebView-rendered surfaces (docs/design/39-webview-markdown.md MD12).
#
# WHY THIS EXISTS
# The summary / Watchers / chat tabs and the diagram zoom overlay are WKWebView pages now. Their text
# is not reliably reachable through the AX tree, and `ax_click.py` cannot address an element inside a
# web view at all -- the copy / retry / zoom buttons all live in the page. `evaluateJavaScript` is an
# in-process API, so this script asks the app to run it via `kikimi://debug/webview` and writes the
# result to a file we can read.
#
# THE APP MUST BE LAUNCHED WITH THE BRIDGE ENABLED. The route is inert otherwise (`DebugBridgeMode`):
#   with_env.sh KIKIMI_DEBUG_BRIDGE=1 -- ~/Applications/Kikimi.app/Contents/MacOS/Kikimi
# `KIKIMI_TEST_HIDDEN=1` and `KIKIMI_STUB_LLM=1` also enable it, so a normal verification launch
# already has it.
#
# PREFER `wait` OVER `dump` when checking that something rendered: rendering is asynchronous (the
# mermaid pass in particular), so a single dump can catch a half-drawn page.
#
# Usage:
#   webview.sh dump  <summary|watchers|chat|diagram> [outfile]
#   webview.sh wait  <target> <substring> [timeout_seconds]   # polls dump until it contains substring
#   webview.sh click <target> <data-testid>
#
# Exit status: 0 on success, 1 on failure (no web view, element not found, timeout).
set -euo pipefail

usage() {
  sed -n '2,26p' "$0" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
action="$1"
target="$2"

case "$target" in
  summary | watchers | chat | diagram) ;;
  *)
    echo "unknown target: $target (expected summary|watchers|chat|diagram)" >&2
    exit 2
    ;;
esac

# A per-invocation path: a leftover file from an earlier run would otherwise be read as this run's
# result when the app never responds.
tmp_out="${TMPDIR:-/tmp}/kikimi-webview-$$-$RANDOM.txt"
cleanup() { rm -f "$tmp_out"; }
trap cleanup EXIT

# `open` returns immediately; the app handles the URL asynchronously.
fire() {
  /usr/bin/open "$1"
}

# Waits for the app to write $tmp_out. 5s is generous for a `evaluateJavaScript` round trip and short
# enough that a disabled bridge fails fast.
await_file() {
  local deadline=$((SECONDS + ${1:-5}))
  while ((SECONDS < deadline)); do
    [[ -s "$tmp_out" ]] && return 0
    sleep 0.1
  done
  return 1
}

do_dump() {
  rm -f "$tmp_out"
  fire "kikimi://debug/webview?target=${target}&action=dump&out=${tmp_out}"
  await_file || {
    echo "no response from Kikimi. Is the app running with KIKIMI_DEBUG_BRIDGE=1, and is the ${target} surface open?" >&2
    return 1
  }
  cat "$tmp_out"
}

case "$action" in
  dump)
    outfile="${3:-}"
    if [[ -n "$outfile" ]]; then
      do_dump >"$outfile"
      echo "wrote $(wc -c <"$outfile" | tr -d ' ') bytes to $outfile"
    else
      do_dump
    fi
    ;;

  wait)
    [[ $# -ge 3 ]] || usage
    needle="$3"
    timeout="${4:-10}"
    deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
      if text="$(do_dump 2>/dev/null)" && [[ "$text" == *"$needle"* ]]; then
        echo "PASS: ${target} contains: ${needle}"
        exit 0
      fi
      sleep 0.5
    done
    echo "FAIL: ${target} did not contain '${needle}' within ${timeout}s" >&2
    echo "--- last dump ---" >&2
    do_dump 2>/dev/null | head -40 >&2 || echo "(no dump available)" >&2
    exit 1
    ;;

  click)
    [[ $# -ge 3 ]] || usage
    testid="$3"
    rm -f "$tmp_out"
    fire "kikimi://debug/webview?target=${target}&action=click&testid=${testid}&out=${tmp_out}"
    await_file || {
      echo "no response from Kikimi (bridge disabled, or ${target} has no web view yet)" >&2
      exit 1
    }
    result="$(cat "$tmp_out")"
    if [[ "$result" == "clicked" ]]; then
      echo "PASS: clicked ${testid} in ${target}"
    else
      echo "FAIL: no element with data-testid=${testid} in ${target}" >&2
      exit 1
    fi
    ;;

  *)
    usage
    ;;
esac
