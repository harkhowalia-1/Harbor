#!/bin/bash
# Signs dist/Harbor.app and wraps it in a disk image.
#
#   scripts/package-dmg.sh [output.dmg]          (default: dist/Harbor.dmg)
#
# Without secrets everything is signed ad hoc (people right-click › Open the first time). With these
# environment variables it is signed with Developer ID and notarized, so it opens with a double-click:
#   MAC_SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID1234)"
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (an app-specific password)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Harbor.app"
OUTPUT="${1:-$ROOT/dist/Harbor.dmg}"
IDENTITY="${MAC_SIGN_IDENTITY:--}"
STAGE="$ROOT/build/dmg"
[ -d "$APP" ] || { echo "No $APP; run scripts/build.sh first" >&2; exit 1; }

SIGN=(codesign --force --sign "$IDENTITY" --options runtime)
if [ "$IDENTITY" != "-" ]; then
    SIGN+=(--timestamp)
    echo "• Signing with $IDENTITY"
else
    echo "• Signing ad hoc (no MAC_SIGN_IDENTITY)"
fi
# Inside out: the runtime libraries Harbor copies into every converted app, the CLI, then the app.
for item in "$APP/Contents/Resources/Runtime/"*.dylib "$APP/Contents/Resources/bin/harbor"; do
    "${SIGN[@]}" "$item"
done
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "• Disk image"
rm -rf "$STAGE" "$OUTPUT"
mkdir -p "$STAGE" "$(dirname "$OUTPUT")"
cp -R "$APP" "$STAGE/"
# Styled with create-dmg when it is installed (brew install create-dmg), plain otherwise.
if command -v create-dmg >/dev/null && create-dmg \
        --volname "Harbor" \
        --volicon "$APP/Contents/Resources/Harbor.icns" \
        --background "$ROOT/dmg/background.png" \
        --window-pos 200 120 --window-size 600 400 --icon-size 112 --text-size 13 \
        --icon "Harbor.app" 165 200 --hide-extension "Harbor.app" \
        --app-drop-link 435 200 \
        --no-internet-enable \
        "$OUTPUT" "$STAGE/" >/dev/null; then
    echo "  styled with create-dmg"
else
    rm -f "$OUTPUT"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Harbor" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT" >/dev/null
fi
rm -rf "$STAGE"

if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$OUTPUT"
    if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
        xcrun notarytool submit "$OUTPUT" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
            --password "$NOTARY_PASSWORD" --wait
        xcrun stapler staple "$OUTPUT"
    fi
fi
echo "✓ $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
