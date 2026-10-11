#!/bin/bash
# Publishes one release the way the website and the updater expect it:
#   1. a GitHub release "v<version>" with the DMG under its versioned name and again as Feather.dmg, so
#      https://github.com/<repo>/releases/latest/download/Feather.dmg always fetches the newest version;
#   2. public/release.json in the website folder (WEBSITE_DIR, beside this repository), which the site reads
#      for the version, size, date and links;
#   3. public/appcast.xml there, the update feed Feather's copies read (served by the website's host).
# release.sh calls this after signing and notarizing; it can be run on its own to redo the publishing.
#   tools/publish_release.sh <version> <releases folder> [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_REPO="${GITHUB_REPO:-}"
source ./release.config
GITHUB_REPO="${ENV_REPO:-${GITHUB_REPO:-}}"          # the environment wins, for trying the script out
VERSION="$1"; OUT="$2"; DRY=0
[[ "${3:-}" == "--dry-run" ]] && DRY=1
[[ -n "${GITHUB_REPO:-}" ]] || { echo "Set GITHUB_REPO in release.config, for example GITHUB_REPO=\"aagicorp/feather\" (the repository on GitHub)."; exit 1; }
DMG="$OUT/Feather-$VERSION.dmg"
NOTES_HTML="$OUT/Feather-$VERSION.html"
[[ -f "$DMG" ]] || { echo "no $DMG"; exit 1; }
[[ -f "$OUT/appcast.xml" ]] || { echo "no $OUT/appcast.xml"; exit 1; }
command -v gh >/dev/null || { echo "The GitHub command-line tool is needed: brew install gh, then gh auth login"; exit 1; }

run() { if [[ $DRY == 1 ]]; then echo "+ $*"; else "$@"; fi; }

# The notes for the GitHub release page: the version's section of CHANGELOG.md, as it is.
NOTES_MD="$OUT/Feather-$VERSION.md"
python3 - "$VERSION" CHANGELOG.md "$NOTES_MD" <<'PY'
import re, sys
version, source, out = sys.argv[1:4]
lines = open(source, encoding="utf-8").read().splitlines()
heading = re.compile(r"^## " + re.escape(version) + r"( \(required\))?\s*$")
start = next(i for i, l in enumerate(lines) if heading.match(l.strip()))
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
open(out, "w", encoding="utf-8").write("\n".join(lines[start + 1:end]).strip() + "\n")
PY

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
say "GitHub release v$VERSION in $GITHUB_REPO"
LATEST="$OUT/Feather.dmg"
cp "$DMG" "$LATEST"
if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    run gh release upload "v$VERSION" "$DMG" "$LATEST" --repo "$GITHUB_REPO" --clobber
else
    run gh release create "v$VERSION" "$DMG" "$LATEST" --repo "$GITHUB_REPO" --title "Feather $VERSION" --notes-file "$NOTES_MD"
fi
rm -f "$LATEST"

# The website is its own folder beside this repository (WEBSITE_DIR in release.config).
WEB="${WEBSITE_DIR:-../FeatherWebsite}"
say "Writing $WEB/public/release.json and $WEB/public/appcast.xml"
SIZE_BYTES=$(stat -f %z "$DMG")
SIZE_MB=$(python3 -c "print(f'{$SIZE_BYTES/1048576:.1f} MB')")
DATE=$(date -u +%Y-%m-%d)
mkdir -p "$WEB/public"
TARGET="$WEB/public/release.json"
[[ $DRY == 1 ]] && TARGET="/dev/stdout" && echo "+ write $WEB/public/release.json:"
cat > "$TARGET" <<JSON
{
  "version": "$VERSION",
  "date": "$DATE",
  "size": "$SIZE_MB",
  "sizeBytes": $SIZE_BYTES,
  "repo": "$GITHUB_REPO",
  "dmg": "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/Feather-$VERSION.dmg",
  "latest": "https://github.com/$GITHUB_REPO/releases/latest/download/Feather.dmg",
  "notes": "https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
}
JSON
run cp "$OUT/appcast.xml" "$WEB/public/appcast.xml"
[[ $DRY == 1 ]] || echo "   $WEB/public/release.json  ->  $VERSION, $SIZE_MB"

if [[ -n "${DEPLOY_WEBSITE_COMMAND:-}" ]]; then
    say "Deploying the website"
    # The command may use $WEBSITE_DIR and $VERSION, as the one in release.config does.
    if [[ $DRY == 1 ]]; then echo "+ $DEPLOY_WEBSITE_COMMAND"; else WEBSITE_DIR="$WEB" VERSION="$VERSION" bash -c "$DEPLOY_WEBSITE_COMMAND"; fi
else
    echo "   Deploy the website now (cd $WEB && npm run build, then upload out/), so the feed and the version text go live."
fi
