#!/bin/bash
# Draws Harbor's graphics from docs/graphics/*.html and the app icon. Outputs are committed:
#   site/assets/  icon-512.png, apple-touch-icon.png, favicon.png, og-image.png (1200x630)
#   docs/assets/  icon.png, banner.png (README)
#   dmg/          background.png, background@2x.png (disk image window)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"

xcrun swiftc -O -o "$WORK/make-harbor-icon" scripts/make-harbor-icon.swift
xcrun swiftc -O -o "$WORK/render-html" scripts/render-html.swift
"$WORK/make-harbor-icon" "$WORK/Harbor.iconset"

mkdir -p site/assets docs/assets dmg
cp "$WORK/Harbor.iconset/icon_512x512.png" site/assets/icon-512.png
cp "$WORK/Harbor.iconset/icon_512x512@2x.png" docs/assets/icon.png
sips -z 180 180 "$WORK/Harbor.iconset/icon_256x256.png" --out site/assets/apple-touch-icon.png >/dev/null
cp "$WORK/Harbor.iconset/icon_32x32@2x.png" site/assets/favicon.png

"$WORK/render-html" docs/graphics/og.html site/assets/og-image.png 1200 630
"$WORK/render-html" docs/graphics/og.html docs/assets/banner.png 1600 560
"$WORK/render-html" docs/graphics/dmg-background.html dmg/background.png 600 400 1
"$WORK/render-html" docs/graphics/dmg-background.html dmg/background@2x.png 600 400 2
echo "✓ Graphics written"
