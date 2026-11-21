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
# The version from the latest git tag (v1.2.0 or 1.2.0), if there is one.
TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --match '[0-9]*' 2>/dev/null) &&
    plutil -replace CFBundleShortVersionString -string "${TAG#v}" "$APP/Contents/Info.plist"
cp -R Resources/. "$APP/Contents/Resources/"  # icon and translations (*.lproj)
strip -x "$APP/Contents/MacOS/picoTranslator"

if [ -z "$SIGN_ID" ]; then
    ids=$(security find-identity -v -p codesigning)
    SIGN_ID=$(echo "$ids" | awk '/"Developer ID Application/ {print $2; exit}')
    [ -z "$SIGN_ID" ] && SIGN_ID=$(echo "$ids" | awk '/"Apple Development/ {print $2; exit}')
    [ -z "$SIGN_ID" ] && SIGN_ID=-
fi
codesign --force --options runtime --entitlements picoTranslator.entitlements -s "$SIGN_ID" "$APP"
echo "Built $APP (signed with ${SIGN_ID%"${SIGN_ID#????????}"}…)"
