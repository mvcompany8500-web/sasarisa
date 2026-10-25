#!/bin/zsh
# Build Sasarisa (사사리사, formerly Mac Butler) → build/Sasarisa.app
#   ./build.sh              ad-hoc signed (macOS asks for permissions again after each rebuild)
#   SIGN_ID="Apple Development: You (TEAMID)" ./build.sh   keeps permissions across rebuilds
# Optional local overrides (not committed): local.env  (APP_NAME, BUNDLE_ID, SIGN_ID)
set -e
cd "${0:a:h}"
_A=$APP_NAME; _B=$BUNDLE_ID; _S=$SIGN_ID          # values passed on the command line win over local.env
[[ -f local.env ]] && source local.env
APP_NAME=${_A:-$APP_NAME}; BUNDLE_ID=${_B:-$BUNDLE_ID}; SIGN_ID=${_S:-$SIGN_ID}
APP_NAME=${APP_NAME:-Sasarisa}
BUNDLE_ID=${BUNDLE_ID:-com.macbutler.app}
SIGN_ID=${SIGN_ID:--}
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
BUILD_DIR=${BUILD_DIR:-build}
APP=$BUILD_DIR/$APP_NAME.app

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDisplayName</key><string>Sasarisa</string>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Sasarisa listens for its name. Audio never leaves your Mac.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>On-device speech recognition turns your voice into text.</string>
<key>NSAppleEventsUsageDescription</key><string>To open and control apps when you ask.</string>
</dict></plist>
PLIST

echo "› compiling app"
# Runs on macOS 14 (Sonoma) and later, on Apple silicon and Intel — without -target, swiftc builds for this Mac's own
# macOS and chip only (10/26: an M2 on Sonoma couldn't open 0.7.1). ARCHS="arm64" builds just one chip (faster, owner builds).
MINOS="${MINOS:-14.0}"
ARCHS="${ARCHS:-arm64 x86_64}"
# swiftc for each chip, then one universal file
uni() {
  local out="$1"; shift
  local parts=()
  for a in ${=ARCHS}; do
    swiftc -O -target "$a-apple-macos$MINOS" "$@" -o "$out.$a"
    parts+=("$out.$a")
  done
  lipo -create "${parts[@]}" -output "$out" && rm -f "${parts[@]}"
}
uni "$APP/Contents/MacOS/$APP_NAME" -swift-version 5 Sources/MacButler/*.swift \
  -framework AppKit -framework AVFoundation -framework Speech -framework QuartzCore -framework ApplicationServices -framework SwiftUI
echo "› compiling tools"
uni "$APP/Contents/Resources/bin/jax" Tools/jax.swift
uni "$APP/Contents/Resources/bin/butler" Tools/butler.swift
uni "$APP/Contents/Resources/bin/butler-mcp" Tools/mcp.swift
cp Tools/jclick Tools/jtype "$APP/Contents/Resources/bin/"
cp -R Resources/prompts "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"     # the orb-and-rings icon (10/25: System Settings showed a blank one)
if [[ "$SIGN_ID" == Developer\ ID* ]]; then
  # Release signing: hardened runtime + entitlements (needed for notarization)
  for t in "$APP"/Contents/Resources/bin/*; do codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$t" >/dev/null; done
  codesign --force --options runtime --timestamp --entitlements Resources/MacButler.entitlements --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" >/dev/null
else
  codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" >/dev/null
fi
echo "✓ $PWD/$APP ($VERSION, $BUNDLE_ID)"
