#!/bin/sh
# Builds an ad-hoc-signed OpenProxy.app from the release build.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

app="build/OpenProxy.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"

cp .build/release/OpenProxyApp "$app/Contents/MacOS/OpenProxyApp"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/dev.openproxy.app.plist "$app/Contents/Library/LaunchAgents/dev.openproxy.app.plist"

codesign --force --sign - "$app"
echo "built $app"
