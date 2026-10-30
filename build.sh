#!/bin/zsh
# Builds "Apple Super Resolution Video Upscaler.app" next to this script.
set -euo pipefail
cd "${0:A:h}"

APP="Apple Super Resolution Video Upscaler.app"

[[ -f Resources/AppIcon.icns ]] || swift Tools/MakeIcon.swift Resources/AppIcon.icns Resources/AppIcon.png

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
    -target arm64-apple-macos26.0 \
    -module-name VideoUpscaler \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Apple Super Resolution Video Upscaler"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
