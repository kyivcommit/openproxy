#!/bin/sh
# Builds an ad-hoc-signed OpenProxy.app (with its root helper daemon) from the release build.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

app="build/OpenProxy.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
	"$app/Contents/Library/LaunchAgents" "$app/Contents/Library/LaunchDaemons"

cp .build/release/OpenProxyApp "$app/Contents/MacOS/OpenProxyApp"
cp .build/release/OpenProxyHelper "$app/Contents/MacOS/OpenProxyHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/dev.openproxy.helperd3.plist "$app/Contents/Library/LaunchDaemons/dev.openproxy.helperd3.plist"
# Compatibility stubs from the old build: bundled only so LegacyMigration can unregister the
# old services. The app never registers them.
cp Resources/legacy/dev.openproxy.app.plist "$app/Contents/Library/LaunchAgents/dev.openproxy.app.plist"
cp Resources/legacy/dev.openproxy.helper.plist "$app/Contents/Library/LaunchDaemons/dev.openproxy.helper.plist"

# Sign nested code first, then the app; avoid --deep (it re-signs the helper unnecessarily and
# can change the binary hash launchd recorded for the daemon). SMAppService.daemon needs a
# signature, not an Apple Developer ID.
codesign --force --sign - "$app/Contents/MacOS/OpenProxyHelper"
codesign --force --sign - "$app/Contents/MacOS/OpenProxyApp"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "built $app"
