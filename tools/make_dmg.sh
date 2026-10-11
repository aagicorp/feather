#!/bin/bash
# Makes the installer disk image: Feather.app on the left, a link to Applications on the right, the arrow and
# the instruction drawn on the background (Resources/dmg/background.tiff), the window at a fixed size with no
# toolbar or sidebar, the app's icon on the volume. Finder lays the window out through AppleScript on a
# read-write image, which is then compressed.
#   tools/make_dmg.sh <Feather.app> <output.dmg> "<volume name>"
set -euo pipefail
APP="$1"; DMG="$2"; VOLNAME="$3"
cd "$(dirname "$0")/.."
[[ -d "$APP" ]] || { echo "no app at $APP"; exit 1; }
STAGE="$(mktemp -d)"
RW="$(mktemp -d)/rw.dmg"
trap 'rm -rf "$STAGE" "$(dirname "$RW")"' EXIT

ditto "$APP" "$STAGE/Feather.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg/background.tiff "$STAGE/.background/background.tiff"

# Room for the app plus the layout files; the compressed image only takes what is used.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | sed -E 's/.*(\/Volumes\/.*)$/\1/' | tail -1)"
[[ -d "$MOUNT" ]] || { echo "could not mount $RW"; exit 1; }
# The volume's icon: the file must be on the volume itself, and the volume flagged "has custom icon".
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "$MOUNT" 2>/dev/null || true

# Window 660×400 at the top left of the screen; icons 128 wide with their labels under them.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {120, 120, 780, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 13
        set label position of theViewOptions to bottom
        set background picture of theViewOptions to file ".background:background.tiff"
        set position of item "Feather.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        close
        open
        delay 1
        close
    end tell
end tell
APPLESCRIPT
# Finder's "update" would delete .VolumeIcon.icns, so the script never asks for one; the icon goes in last.
[[ -f "$MOUNT/.VolumeIcon.icns" ]] || cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
sync
# Finder keeps the layout in .DS_Store; let it finish writing before the volume goes away.
sleep 1
hdiutil detach "$MOUNT" -quiet || { sleep 2; hdiutil detach "$MOUNT" -force -quiet; }
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "made $DMG"
