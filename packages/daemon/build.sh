#!/usr/bin/env bash
# Builds "Presence Capture.app" from this package: the release binary, its Info.plist, signed.
# Signed with an Apple Development identity when this Mac has one, so macOS keeps the Screen
# Recording permission across rebuilds; otherwise ad hoc (the permission is asked again each build).
# Usage: packages/daemon/build.sh [out-dir]   (default packages/daemon/.build/app)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-${SCRIPT_DIR}/.build/app}"
APP="${OUT_DIR}/Presence Capture.app"
# Reverse-DNS of presenceos.ai. It names the app to macOS: its permissions, its settings and its
# Keychain item all follow it, so a build under another ID starts afresh with none of them.
BUNDLE_ID="${PRESENCE_CAPTURE_BUNDLE_ID:-ai.presenceos.capture}"
# By hash: a keychain can hold two certificates of one name, which codesign won't choose between.
IDENTITY="${PRESENCE_CAPTURE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "Apple Development: .*/\1/p' | head -n 1)}"
IDENTITY="${IDENTITY:--}"
BUILD_NUMBER="$(git -C "${SCRIPT_DIR}" rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --package-path "${SCRIPT_DIR}" --product PresenceCapture
BIN_DIR="$(swift build -c release --package-path "${SCRIPT_DIR}" --show-bin-path)"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp "${BIN_DIR}/PresenceCapture" "${APP}/Contents/MacOS/PresenceCapture"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Presence Capture</string>
  <key>CFBundleDisplayName</key><string>Presence Capture</string>
  <key>CFBundleExecutable</key><string>PresenceCapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Presence Capture turns what your microphone hears into words on this Mac. No audio is kept, and nothing leaves this Mac.</string>
</dict>
</plist>
PLIST
plutil -lint "${APP}/Contents/Info.plist" >/dev/null

codesign --force --options runtime --entitlements "${SCRIPT_DIR}/PresenceCapture.entitlements" --sign "${IDENTITY}" "${APP}"
codesign --verify --strict "${APP}"
echo "built: ${APP} (signed: ${IDENTITY})"
