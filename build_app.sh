#!/bin/sh
# Builds SpinelSvn.app (release) into ./build.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/SpinelSvn.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpinelSvn "$APP/Contents/MacOS/SpinelSvn"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Support/ja.lproj Support/en.lproj "$APP/Contents/Resources/"
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift Support/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
codesign --force --sign - "$APP"
echo "Built $APP"
