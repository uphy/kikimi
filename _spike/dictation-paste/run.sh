#!/usr/bin/env bash
# Builds the spike into a .app bundle and launches it.
#
# The bundle is not optional: TCC identifies Accessibility clients by bundle id
# + code signature. Running the bare executable from a terminal would attribute
# the permission to the terminal emulator instead, which is exactly the kind of
# false signal this spike must avoid.
set -euo pipefail

cd "$(dirname "$0")"

app="build/DictationSpike.app"

# `--no-build` relaunches the existing bundle untouched. Rebuilding re-signs it,
# which changes the cdhash and invalidates the Accessibility grant — so once the
# permission is in place, use this to restart without losing it.
if [ "${1:-}" = "--no-build" ]; then
  pkill -f DictationSpike >/dev/null 2>&1 || true
  sleep 0.3
  open "$app"
  echo "relaunched (no rebuild). log: tail -f /tmp/dictation-spike.log"
  exit 0
fi

swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

cp .build/release/DictationSpike "$app/Contents/MacOS/DictationSpike"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>DictationSpike</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.uphy.DictationSpike</string>
	<key>CFBundleName</key>
	<string>DictationSpike</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.2</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with the shared local dev certificate (`mise run signing-identity` in the repo
# root) so the designated requirement references the certificate rather than the cdhash.
# Otherwise every rebuild silently revokes the Accessibility grant.
# Queried without -v: a self-signed cert is never reported as "valid".
identity="Kikimi Local Dev"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$identity"; then
  codesign --force --sign "$identity" --identifier io.github.uphy.DictationSpike "$app"
else
  codesign --force --sign - "$app" >/dev/null 2>&1
  echo "WARNING: no '$identity' — signed ad-hoc; Accessibility will be revoked on rebuild."
  echo "         Fix once with: (cd ../.. && mise run signing-identity)"
fi

pkill -f DictationSpike >/dev/null 2>&1 || true
sleep 0.3
open "$app"

echo "launched. log: tail -f /tmp/dictation-spike.log"
