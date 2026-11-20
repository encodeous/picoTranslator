#!/bin/sh
# Builds build/picoTranslator.app (release, size-optimized, stripped, signed).
#
# Signing: macOS remembers the Screen Recording permission per code identity. An ad-hoc signature
# changes on every build, so macOS would ask again after each rebuild. With a real certificate the
# identity stays the same. Override with SIGN_ID="<identity>" ./build.sh, or SIGN_ID=- for ad-hoc.
set -e
cd "$(dirname "$0")"
swift build -c release -Xswiftc -Osize -Xlinker -dead_strip
APP=build/picoTranslator.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/picoTranslator "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
strip -x "$APP/Contents/MacOS/picoTranslator"

if [ -z "$SIGN_ID" ]; then
    ids=$(security find-identity -v -p codesigning)
    SIGN_ID=$(echo "$ids" | awk '/"Developer ID Application/ {print $2; exit}')
    [ -z "$SIGN_ID" ] && SIGN_ID=$(echo "$ids" | awk '/"Apple Development/ {print $2; exit}')
    [ -z "$SIGN_ID" ] && SIGN_ID=-
fi
codesign --force --options runtime --entitlements picoTranslator.entitlements -s "$SIGN_ID" "$APP"
echo "Built $APP (signed with ${SIGN_ID%"${SIGN_ID#????????}"}…)"
