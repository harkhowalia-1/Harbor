#!/bin/bash
# Builds dist/Harbor.app: the SwiftUI library app, the `harbor` CLI and the injected runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Harbor.app"
WORK="$ROOT/build"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
cd "$ROOT"

echo "• Runtime"
./scripts/build-runtime.sh "$WORK/Runtime" >/dev/null

echo "• Harbor and harbor CLI (release)"
swift build -c release --product HarborApp >/dev/null
swift build -c release --product harbor >/dev/null
BIN="$(swift build -c release --show-bin-path)"

echo "• Icon"
xcrun swiftc -O -o "$WORK/make-harbor-icon" scripts/make-harbor-icon.swift
rm -rf "$WORK/Harbor.iconset"
"$WORK/make-harbor-icon" "$WORK/Harbor.iconset"

echo "• Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Runtime" "$APP/Contents/Resources/bin"
cp "$BIN/HarborApp" "$APP/Contents/MacOS/Harbor"
cp "$BIN/harbor" "$APP/Contents/Resources/bin/harbor"
cp "$WORK/Runtime/libHarborRuntime.dylib" "$WORK/Runtime/libHarborAppKit.dylib" "$WORK/Runtime/libHarborWebMedia.dylib" \
   "$APP/Contents/Resources/Runtime/"
iconutil -c icns -o "$APP/Contents/Resources/Harbor.icns" "$WORK/Harbor.iconset"
rm -rf "$WORK/Harbor.iconset" "$WORK/make-harbor-icon"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>app.harbor.Harbor</string>
	<key>CFBundleName</key><string>Harbor</string>
	<key>CFBundleDisplayName</key><string>Harbor</string>
	<key>CFBundleExecutable</key><string>Harbor</string>
	<key>CFBundleIconFile</key><string>Harbor</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>iOS App Package</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key><array><string>com.apple.itunes.ipa</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/Runtime/"*.dylib "$APP/Contents/Resources/bin/harbor" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
echo "✓ $APP"
echo "  CLI: $APP/Contents/Resources/bin/harbor"
