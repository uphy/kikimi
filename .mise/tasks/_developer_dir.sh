#!/usr/bin/env bash
# Resolve DEVELOPER_DIR to an Xcode.app. Sourced by the build and test tasks.
#
# Xcode is required for two separate reasons:
#   - the Metal compiler (Command Line Tools has none), without which mlx-swift ships no
#     `default.metallib` and every MLX call traps at runtime
#   - swift-testing, which the Xcode toolchain bundles and the Command Line Tools one does not
#     ("no such module 'Testing'")
#
# `xcode-select -p` is deliberately left pointing at the Command Line Tools so unrelated tools
# keep their current behaviour -- notably SwiftLint's sourcekit lookup in
# `.mise/tasks/lint/_default`. Hence the explicit search rather than switching system-wide.
resolve_developer_dir() {
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode*.app; do
      [ -d "$candidate/Contents/Developer" ] && DEVELOPER_DIR="$candidate/Contents/Developer"
    done
  fi
  if [ -z "${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    echo "error: Xcode not found. Install it, then re-run, or set DEVELOPER_DIR to its" >&2
    echo "       Contents/Developer. Command Line Tools alone is not enough: it has neither" >&2
    echo "       the Metal compiler nor swift-testing." >&2
    return 1
  fi
  export DEVELOPER_DIR
}
