#!/bin/bash
# Builds Feather.app.
#   ./build.sh              a development build for this Mac: ad-hoc signed, never looks for updates
#   ./build.sh --release    universal binary with the update feed in it; release.sh signs and ships it
#   ./build.sh --team       universal binary without an update feed, for a DMG handed to the team directly
#   ./build.sh --lab        a release build for this Mac whose update feed is http://localhost:8765/appcast.xml
#                           (tools/update-lab.sh uses it to try an update end to end)
set -euo pipefail
cd "$(dirname "$0")"
source ./release.config

RELEASE=0
UNIVERSAL_BUILD=0
[[ "${1:-}" == "--release" ]] && RELEASE=1 && UNIVERSAL_BUILD=1
[[ "${1:-}" == "--team" ]] && UNIVERSAL_BUILD=1
if [[ "${1:-}" == "--lab" ]]; then
    RELEASE=1
    FEED_URL="${LAB_FEED_URL:-http://localhost:8765/appcast.xml}"
fi
VERSION="$(tr -d '[:space:]' < VERSION)"

if [[ $RELEASE == 1 ]]; then
    [[ -n "$FEED_URL" && -n "$SPARKLE_PUBLIC_KEY" ]] || { echo "release.config needs FEED_URL and SPARKLE_PUBLIC_KEY (run ./release.sh setup)"; exit 1; }
fi
if [[ $UNIVERSAL_BUILD == 1 ]]; then
    # Apple silicon and Intel in one binary. Each is built on its own and the two are joined: SwiftPM's
    # one-step universal build does not get along with a build plugin SwiftTerm uses.
    # The Intel build keeps its own folder; two architectures sharing .build confuse SwiftPM's bookkeeping.
    swift build -c release --triple arm64-apple-macosx
    swift build -c release --triple x86_64-apple-macosx --scratch-path .build-intel
    BIN=".build/arm64-apple-macosx/release"          # the Sparkle framework in it is universal already
    UNIVERSAL="$(mktemp -d)/Feather"
    lipo -create "$BIN/Feather" ".build-intel/x86_64-apple-macosx/release/Feather" -output "$UNIVERSAL"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)"
fi

APP="Feather.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "${UNIVERSAL:-$BIN/Feather}" "$APP/Contents/MacOS/Feather"
# ditto keeps the framework's symbolic links, which a code signature depends on.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp -R Resources/icons "$APP/Contents/Resources/icons"
# Tree-sitter highlight queries, one folder per grammar (see Resources/queries/README.md).
cp -R Resources/queries "$APP/Contents/Resources/queries"
# Regenerate the icon with: python3 tools/make_icon.py
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Shown in the app as "What's New".
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
# The licences of what is linked in travel with the app, as MIT and BSD ask.
[[ -f THIRD-PARTY-LICENSES.txt ]] && cp THIRD-PARTY-LICENSES.txt "$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt"

UPDATE_KEYS=""
if [[ $RELEASE == 1 ]]; then
    UPDATE_KEYS="    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Feather</string>
    <key>CFBundleDisplayName</key><string>Feather</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Feather</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Aatvaas Granger Internationals Inc. Open source under the Apache License 2.0.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
        <!-- The preview visits localhost under a stand-in name (see PreviewAlias); it is this Mac and nothing else. -->
        <key>NSExceptionDomains</key>
        <dict>
            <key>fthr.localhost</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
        </dict>
    </dict>
$UPDATE_KEYS
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Feather link</string>
            <key>CFBundleURLSchemes</key><array><string>feather</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Text or Folder</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.text</string>
                <string>public.data</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ $UNIVERSAL_BUILD == 0 ]]; then
    # A lab build is signed like a release when a Developer ID certificate is here, so Sparkle sees the old and
    # the new app as the same publisher; otherwise ad hoc, which Sparkle accepts with the EdDSA signature alone.
    LAB_IDENTITY=""
    [[ "${1:-}" == "--lab" ]] && LAB_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
    if [[ -n "$LAB_IDENTITY" ]]; then
        codesign --force --deep --options runtime --sign "$LAB_IDENTITY" "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
    else
        codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
    fi
fi
echo "Built $(pwd)/$APP  (version $VERSION$([[ $RELEASE == 1 ]] && echo ', release'))"
