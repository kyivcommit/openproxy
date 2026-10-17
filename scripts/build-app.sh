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
cp Resources/dev.openproxy.app.plist "$app/Contents/Library/LaunchAgents/dev.openproxy.app.plist"
cp Resources/dev.openproxy.helper.plist "$app/Contents/Library/LaunchDaemons/dev.openproxy.helper.plist"

# Sign the whole bundle (app + helper) ad-hoc; SMAppService.daemon needs a signature, not an
# Apple Developer ID.
codesign --force --deep --sign - "$app"
codesign -v "$app"
echo "built $app"
