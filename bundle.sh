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
    <string>NotchMVP đọc và điều khiển nhạc đang phát trong Apple Music, Spotify và trình duyệt.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>NotchMVP dùng vị trí của bạn để hiển thị thời tiết hiện tại.</string>
    <key>NSHumanReadableCopyright</key>
    <string>NotchMVP</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS lets it request Automation permission reliably.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
