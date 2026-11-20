#!/bin/sh
# Packages picoTranslator for distribution, as a universal (Apple silicon + Intel) app in dist/.
#
#   ./bundle.sh appstore   dist/picoTranslator.pkg for App Store Connect. Upload it with Transporter.
#       Needs: an "Apple Distribution" and a "Mac Installer Distribution" certificate in your keychain,
#       and the app's Mac App Store provisioning profile in signing/ (git-ignored), or PROFILE=<path>.
#
#   ./bundle.sh release    dist/picoTranslator.dmg, signed with Developer ID and notarized, for GitHub
#       Releases and Homebrew. Needs: a "Developer ID Application" certificate, and notary credentials
#       saved once with: xcrun notarytool store-credentials picoTranslator
#
# Optional: BUILD=<build number> (default: a timestamp; App Store Connect needs it to increase every upload),
# APP_ID / INSTALLER_ID (signing identities), NOTARY_PROFILE (default "picoTranslator"),
# NOTARIZE=0 (release: skip notarizing, to check the disk image quickly).
set -e
cd "$(dirname "$0")"
MODE=$1
case "$MODE" in appstore | release) ;; *) echo "usage: ./bundle.sh appstore|release" >&2; exit 1 ;; esac

BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
APP=dist/picoTranslator.app

FLAGS="-c release --arch arm64 --arch x86_64 -Xswiftc -Osize"
swift build $FLAGS
rm -rf "$APP" dist/dmg && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"  # keeps the other mode's output
cp "$(swift build $FLAGS --show-bin-path)/picoTranslator" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/. "$APP/Contents/Resources/"  # icon and translations (*.lproj)
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/picoTranslator"

if [ "$MODE" = appstore ]; then
    PROFILE=${PROFILE:-$(ls signing/*.provisionprofile 2>/dev/null | head -1)}
    [ -f "$PROFILE" ] || { echo "Put the app's Mac App Store provisioning profile in signing/, or set PROFILE." >&2; exit 1; }
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    xattr -cr "$APP"  # a downloaded profile carries com.apple.quarantine, which the App Store rejects
    # The App Store also needs the app and team identifiers, taken from the profile.
    TEAM=$(security cms -D -i "$PROFILE" | plutil -extract TeamIdentifier.0 raw -o - -)
    BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw Info.plist)
    cp picoTranslator.entitlements dist/appstore.entitlements
    plutil -insert "com\\.apple\\.application-identifier" -string "$TEAM.$BUNDLE_ID" dist/appstore.entitlements
    plutil -insert "com\\.apple\\.developer\\.team-identifier" -string "$TEAM" dist/appstore.entitlements
    codesign --force --options runtime --entitlements dist/appstore.entitlements -s "${APP_ID:-Apple Distribution}" "$APP"
    # The installer certificate goes by either name, depending on when it was made.
    INSTALLER_ID=${INSTALLER_ID:-$(security find-identity -v | grep -oE '"(Mac Installer Distribution|3rd Party Mac Developer Installer)[^"]*"' | head -1 | tr -d '"')}
    rm -f dist/picoTranslator.pkg
    productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" dist/picoTranslator.pkg
    echo "Built dist/picoTranslator.pkg (build $BUILD). Upload it to App Store Connect with Transporter."
else
    ID=${APP_ID:-Developer ID Application}
    codesign --force --options runtime --timestamp --entitlements picoTranslator.entitlements -s "$ID" "$APP"
    # A disk image with the app and an Applications shortcut to drag it onto, over a background with an
    # arrow (assets/dmg). Finder saves the window layout into the image, so it's arranged by scripting
    # Finder on a writable copy, which is then compressed.
    mkdir -p dist/dmg/.background && mv "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
    cp assets/dmg/background.tiff dist/dmg/.background/
    rm -f dist/picoTranslator.dmg dist/rw.dmg
    hdiutil create -volname picoTranslator -srcfolder dist/dmg -format UDRW -fs HFS+ -quiet dist/rw.dmg
    rm -rf dist/dmg
    ATTACHED=$(hdiutil attach dist/rw.dmg -readwrite -noverify -noautoopen | grep Apple_HFS)
    DEVICE=$(echo "$ATTACHED" | awk '{print $1}')
    VOLUME=$(basename "$(echo "$ATTACHED" | sed 's/.*Apple_HFS[[:space:]]*//')")  # "picoTranslator 1" if one is open already
    osascript - "$VOLUME" <<'EOF'
on run argv
    tell application "Finder" to tell disk (item 1 of argv)
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548} -- 640 x 400, plus the title bar
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "picoTranslator.app" to {170, 190}
        set position of item "Applications" to {470, 190}
        update without registering applications
        delay 1
        close
    end tell
end run
EOF
    sync
    hdiutil detach "$DEVICE" -quiet
    hdiutil convert dist/rw.dmg -format UDZO -quiet -o dist/picoTranslator.dmg
    rm dist/rw.dmg
    codesign --timestamp -s "$ID" dist/picoTranslator.dmg
    [ "$NOTARIZE" = 0 ] && { echo "Built dist/picoTranslator.dmg (build $BUILD), not notarized (NOTARIZE=0)."; exit 0; }
    xcrun notarytool submit dist/picoTranslator.dmg --keychain-profile "${NOTARY_PROFILE:-picoTranslator}" --wait
    xcrun stapler staple dist/picoTranslator.dmg  # so it opens without a warning, even offline
    echo "Built dist/picoTranslator.dmg (build $BUILD), notarized."
fi
