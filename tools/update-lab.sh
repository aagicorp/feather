#!/bin/bash
# Tries an update end to end on this Mac, the way a user will get it: builds the current version as the "old"
# app, builds the next version as a DMG, writes a signed appcast for it, serves both from http://localhost:8765,
# and opens the old app pointed at that feed. Choose Feather ▸ Check for Updates… in it (or pass --check to have
# it checked at once): the new version is offered, Install swaps the app and relaunches it as the new version.
#   tools/update-lab.sh [--critical] [--check] [--keep-serving]
# --critical marks the update critical, as ./release.sh --critical would: no Skip, a card in every window.
# Needs the Sparkle key from ./release.sh setup. Nothing here touches releases/ or the real feed.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./release.config
CRITICAL=0; CHECK=0; KEEP=0
for arg in "$@"; do
    case "$arg" in
        --critical) CRITICAL=1 ;;
        --check) CHECK=1 ;;
        --keep-serving) KEEP=1 ;;
        *) echo "unknown option $arg"; exit 1 ;;
    esac
done
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_appcast" ]] || { echo "Sparkle's tools are not built yet: run swift build once"; exit 1; }
[[ -n "$SPARKLE_PUBLIC_KEY" ]] || { echo "release.config has no SPARKLE_PUBLIC_KEY: run ./release.sh setup"; exit 1; }
PORT=8765
LAB="${LOCAL_DIR:-../Feather-local}/update-lab"            # outside the repository: nothing here is committed
OLD_VERSION="$(tr -d '[:space:]' < VERSION)"
# The next patch version: 0.14.3 becomes 0.14.4.
NEW_VERSION="$(python3 -c "import sys; p=sys.argv[1].split('.'); p[-1]=str(int(p[-1])+1); print('.'.join(p))" "$OLD_VERSION")"
BUNDLE="${BUNDLE_ID:-com.aagicorp.feather}"
pkill -f "http.server $PORT" 2>/dev/null || true
rm -rf "$LAB"
mkdir -p "$LAB/feed" "$LAB/old"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Building the old app, Feather $OLD_VERSION, looking for updates at http://localhost:$PORT/appcast.xml"
./build.sh --lab >/dev/null
ditto Feather.app "$LAB/old/Feather.app"

say "Building the new app, Feather $NEW_VERSION"
cp VERSION "$LAB/VERSION.saved"
trap 'cp "$LAB/VERSION.saved" VERSION 2>/dev/null || true' EXIT
printf '%s\n' "$NEW_VERSION" > VERSION
./build.sh --lab >/dev/null
cp "$LAB/VERSION.saved" VERSION
tools/make_dmg.sh Feather.app "$LAB/feed/Feather-$NEW_VERSION.dmg" "Feather $NEW_VERSION" >/dev/null
cat > "$LAB/feed/Feather-$NEW_VERSION.html" <<HTML
<h2>Feather $NEW_VERSION</h2>
<p>A build from the update lab, made on this Mac at $(date). Installing it proves the update path works:
the feed was read, the signature checked, the app swapped and relaunched.</p>
HTML

say "Writing the feed (signed with the key in your keychain)"
EXTRA=()
[[ $CRITICAL == 1 ]] && EXTRA+=(--critical-update-version "")
"$TOOLS/generate_appcast" "$LAB/feed" --download-url-prefix "http://localhost:$PORT/" -o "$LAB/feed/appcast.xml" "${EXTRA[@]}" >/dev/null
grep -q "sparkle:version=\"$NEW_VERSION\"" "$LAB/feed/appcast.xml" || grep -q "<sparkle:shortVersionString>$NEW_VERSION" "$LAB/feed/appcast.xml" || { echo "the appcast does not list $NEW_VERSION"; exit 1; }
[[ $CRITICAL == 0 ]] || grep -q "criticalUpdate" "$LAB/feed/appcast.xml" || { echo "the appcast is not marked critical"; exit 1; }

say "Serving the feed"
python3 -m http.server "$PORT" --directory "$LAB/feed" >/dev/null 2>&1 &
SERVER=$!
sleep 1
curl -sf "http://localhost:$PORT/appcast.xml" >/dev/null || { echo "the feed is not being served"; exit 1; }

# Back to an ordinary development build in the repository, so nothing lab-specific is left in Feather.app.
./build.sh >/dev/null

say "Opening the old app ($OLD_VERSION)"
if [[ $CHECK == 1 ]]; then open -n "$LAB/old/Feather.app" --args --check-updates-now; else open -n "$LAB/old/Feather.app"; fi
cat <<TEXT

  Old app:  $LAB/old/Feather.app  (version $OLD_VERSION)
  Feed:     http://localhost:$PORT/appcast.xml  ->  Feather $NEW_VERSION$([[ $CRITICAL == 1 ]] && echo ", critical")

  In the old app choose Feather ▸ Check for Updates… (or you passed --check). Sparkle shows $NEW_VERSION with the
  notes above; Install downloads the DMG, checks its signature, swaps the app and relaunches it. Feather ▸ About
  then says $NEW_VERSION. With --critical the dialog has no Skip and every window shows the "Update required" card.

  The feed keeps being served until you press Ctrl-C$([[ $KEEP == 1 ]] && echo " (--keep-serving)" || echo "; it stops by itself in 10 minutes").
TEXT
if [[ $KEEP == 1 ]]; then wait "$SERVER"; else sleep 600; kill "$SERVER" 2>/dev/null || true; fi
