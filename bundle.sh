#!/bin/bash
# Builds a release binary and wraps it in a proper .app bundle.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="NotchMVP.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/NotchMVP "$APP/Contents/MacOS/NotchMVP"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NotchMVP</string>
    <key>CFBundleDisplayName</key>
    <string>NotchMVP</string>
    <key>CFBundleIdentifier</key>
    <string>local.notchmvp.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>NotchMVP</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchMVP reads and controls playback in Apple Music, Spotify, and your browser.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>NotchMVP uses your location to show the current weather.</string>
    <key>NSHumanReadableCopyright</key>
    <string>NotchMVP</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS lets it request Automation permission reliably.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
