#!/bin/bash
# Ships a version of Feather: build, sign, DMG, notarize, update feed.
#   ./release.sh setup            one-time: checks the certificate, makes the update-signing key, explains the rest
#   ./release.sh                  releases the version in the file VERSION
#   ./release.sh --no-notarize    the same without Apple's check, to try the flow (not for handing out)
#   ./release.sh --critical       this version fixes a serious bug: every older copy must install it (no Skip, a
#                                 card in every window, checked at each launch). --critical-below <version> limits
#                                 that to copies older than <version>.
#   ./release.sh --phased <seconds>  roll the update out gradually over that many seconds
#   ./release.sh team             a signed (and, once the login is stored, notarized) DMG to hand to the team
#                                 directly: no website, no update feed; people install the next DMG by hand
# Release notes: add a "## <version>" section to CHANGELOG.md first. It becomes the text of the update window
# and the "What's New" page inside the app. A heading "## <version> (required)" makes the release critical, the
# same as --critical, so the decision is written down with the notes.
set -euo pipefail
cd "$(dirname "$0")"
source ./release.config
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
OUT="releases"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

identity() {
    if [[ -n "$SIGN_IDENTITY" ]]; then echo "$SIGN_IDENTITY"; return; fi
    security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1
}

setup() {
    [[ -d "$TOOLS" ]] || swift package resolve
    say "1. Signing certificate"
    if [[ -n "$(identity)" ]]; then echo "   Found: $(identity)"; else cat <<'TEXT'
   No "Developer ID Application" certificate is in this Mac's keychain. "Apple Distribution" and "Apple
   Development" certificates are for the App Store and for testing; an app handed out as a DMG needs this one.
   Create it (the team's Account Holder has to do it, once):
     Xcode > Settings > Accounts > your team > Manage Certificates > + > Developer ID Application
   then run this again.
TEXT
    fi
    say "2. Update-signing key"
    if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then echo "   release.config already has a public key."; else
        echo "   Creating a key pair. The private key is stored in your login keychain (macOS may ask for permission)."
        "$TOOLS/generate_keys"
        echo "   Copy the SUPublicEDKey value above into SPARKLE_PUBLIC_KEY in release.config."
        echo "   Back the private key up somewhere safe:  $TOOLS/generate_keys -x feather-update-key.txt"
        echo "   Without it you can never ship an update that existing copies will accept."
    fi
    say "3. Notarization credentials"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then echo "   Profile \"$NOTARY_PROFILE\" works."; else cat <<TEXT
   Make an app-specific password at https://account.apple.com (Sign-In and Security), then run:
     xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   It asks for the password and keeps it in the keychain; it never goes into this repository.
TEXT
    fi
    say "4. release.config"
    [[ -n "$FEED_URL" ]] && echo "   FEED_URL = $FEED_URL" || echo "   Set FEED_URL and DOWNLOAD_URL_PREFIX to where appcast.xml and the DMGs will be served (https only)."
}

sign() { codesign --force --timestamp --options runtime --sign "$ID" "$@"; }

release() {
    local notarize=1 team=0 critical="" critical_set=0 phased=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-notarize) notarize=0 ;;
            team) team=1 ;;
            --critical) critical=""; critical_set=1 ;;
            --critical-below) critical="$2"; critical_set=1; shift ;;
            --phased) phased="$2"; shift ;;
            *) fail "Unknown option: $1" ;;
        esac
        shift
    done
    VERSION="$(tr -d '[:space:]' < VERSION)"
    ID="$(identity)"
    [[ -n "$ID" ]] || fail "No Developer ID Application certificate found. Run ./release.sh setup"
    if [[ $team == 1 ]]; then
        # Handed over directly, so nothing is published and the same version may be rebuilt while testing.
        OUT="${LOCAL_DIR:-../Feather-local}/team-builds"
        mkdir -p "$OUT"
        DMG="$OUT/Feather-$VERSION.dmg"
        rm -f "$DMG"
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
            notarize=0
            NOT_NOTARIZED=1
        fi
    else
        # The DMGs live in GitHub Releases: the download address follows from the repository and the version.
        if [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
            [[ -n "${GITHUB_REPO:-}" ]] || fail "Set GITHUB_REPO (owner/name) in release.config; the DMGs go to its Releases"
            DOWNLOAD_URL_PREFIX="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"
        fi
        [[ "$FEED_URL" == https://* ]] || fail "FEED_URL must be an https address"
        DMG="$OUT/Feather-$VERSION.dmg"
        [[ ! -e "$DMG" ]] || fail "$DMG exists already. Raise the number in VERSION: a released version is never rebuilt."
    fi

    # The notes in the update window come from the same CHANGELOG.md the app shows as "What's New".
    if grep -qE "^## $VERSION \(required\)\s*$" CHANGELOG.md; then critical=""; critical_set=1; fi
    mkdir -p "$OUT"
    [[ $team == 1 ]] || python3 tools/release_notes.py "$VERSION" CHANGELOG.md "$OUT/Feather-$VERSION.html" \
        || fail "CHANGELOG.md has no \"## $VERSION\" section. Write the notes for this version first."

    say "Building Feather $VERSION"
    if [[ $team == 1 ]]; then ./build.sh --team; else ./build.sh --release; fi

    say "Signing as $ID"
    local sparkle="Feather.app/Contents/Frameworks/Sparkle.framework/Versions/B"
    # Inside out: a signature covers what is inside it, so the innermost pieces are signed first.
    sign "$sparkle/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
    sign "$sparkle/Autoupdate"
    sign "$sparkle/Updater.app"
    sign "Feather.app/Contents/Frameworks/Sparkle.framework"
    sign "Feather.app"
    codesign --verify --deep --strict "Feather.app"

    say "Making $DMG"
    mkdir -p "$OUT"
    # The window layout (background, icon positions, size) is Finder's work: tools/make_dmg.sh.
    tools/make_dmg.sh "Feather.app" "$DMG" "Feather $VERSION"
    sign "$DMG"

    if [[ $notarize == 1 ]]; then
        say "Sending it to Apple to be notarized (a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature "$DMG" && echo "Gatekeeper accepts it."
    elif [[ "${NOT_NOTARIZED:-0}" == 1 ]]; then
        cat <<TEXT
Signed by $ID, but NOT notarized: the notarization login is not stored yet.
On a teammate's Mac the first launch will be blocked; they can allow it once under
System Settings > Privacy & Security > "Open Anyway". To remove that step, store the login
(see ./release.sh setup, step 3) and run this again.
TEXT
    else
        echo "Skipped notarization: other Macs will refuse to open this DMG."
    fi

    if [[ $team == 1 ]]; then
        say "Done: $DMG"
        echo "   Hand this file to the team (AirDrop, shared drive, Slack). They drag Feather into Applications."
        echo "   This build does not update itself; send the next DMG the same way."
        open -R "$DMG"
        return
    fi

    say "Writing the update feed"
    # Signs every DMG in the folder with the private key from the keychain and rewrites appcast.xml. Release
    # notes are taken from Feather-<version>.html next to the DMG.
    local extra=()
    if [[ $critical_set == 1 ]]; then
        extra+=(--critical-update-version "$critical")
        say "Marked critical: every copy ${critical:+older than $critical }will be told to install it, without Skip."
    fi
    [[ -n "$phased" ]] && extra+=(--phased-rollout-interval "$phased")
    "$TOOLS/generate_appcast" "$OUT" --download-url-prefix "$DOWNLOAD_URL_PREFIX" -o "$OUT/appcast.xml" "${extra[@]}"

    if [[ -n "$UPLOAD_COMMAND" ]]; then
        say "Publishing"
        bash -c "$UPLOAD_COMMAND" upload "$OUT"
    elif [[ -n "${GITHUB_REPO:-}" ]]; then
        # The GitHub release, the website's release.json and the feed copy; the website deploy when configured.
        tools/publish_release.sh "$VERSION" "$OUT"
    else
        say "Done. Publish these two, the DMG first:"
        echo "   $DMG          ->  $DOWNLOAD_URL_PREFIX"
        echo "   $OUT/appcast.xml  ->  $FEED_URL"
    fi
}

case "${1:-}" in
    setup) setup ;;
    ""|--no-notarize|team|--critical|--critical-below|--phased) release "$@" ;;
    *) sed -n '2,9p' "$0" ;;
esac
