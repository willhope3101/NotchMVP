#!/bin/bash
# Builds and installs the one canonical copy in /Applications, then relaunches it.
#
# Keeping a single copy matters: macOS grants Automation/Location per app
# identity, so a second copy elsewhere (Desktop, project folder) shows up as a
# separate entry in Privacy & Security and can run at the same time, leaving two
# panels stacked on the notch.
set -e
cd "$(dirname "$0")"

APP="/Applications/NotchMVP.app"

./bundle.sh

echo "Stopping any running copies…"
pkill -f "NotchMVP.app/Contents/MacOS/NotchMVP" 2>/dev/null || true
sleep 1

echo "Installing to $APP"
rm -rf "$APP"
ditto NotchMVP.app "$APP"
rm -rf NotchMVP.app          # don't leave a second runnable copy behind

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP" 2>/dev/null || true

# Point login-at-startup at the installed copy.
PLIST="$HOME/Library/LaunchAgents/local.notchmvp.launcher.plist"
if [ -f "$PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 $APP" "$PLIST" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/local.notchmvp.launcher" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    echo "Login item now points at $APP"
fi

open "$APP"
echo "Running: $APP"
