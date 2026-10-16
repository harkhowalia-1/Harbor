#!/bin/bash
# Builds TestApp (Harbor Diagnostics) for iPhone hardware and packages it as build/HarborDiag.ipa,
# shaped like an Xcode device build: arm64 iOS binary, asset catalog, loose icon PNGs, signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/TestApp"
APP="$OUT/Payload/HarborDiag.app"
rm -rf "$OUT"
mkdir -p "$APP" "$OUT/Assets.xcassets/AppIcon.appiconset"

echo "• Drawing icon"
xcrun swiftc -O -o "$OUT/make-icon" "$ROOT/TestApp/make-icon.swift"
"$OUT/make-icon" "$OUT/Assets.xcassets/AppIcon.appiconset/icon.png"
cat > "$OUT/Assets.xcassets/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > "$OUT/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{ "images" : [ { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
JSON

echo "• Compiling for arm64-apple-ios16.0"
xcrun -sdk iphoneos swiftc -target arm64-apple-ios16.0 -O -parse-as-library \
    -o "$APP/HarborDiag" "$ROOT/TestApp/HarborDiag.swift"

echo "• Compiling asset catalog"
xcrun actool "$OUT/Assets.xcassets" --compile "$APP" --platform iphoneos \
    --minimum-deployment-target 16.0 --target-device iphone --app-icon AppIcon \
    --output-partial-info-plist "$OUT/partial.plist" --output-format human-readable-text >/dev/null

/usr/bin/python3 -I - "$ROOT/TestApp/Info.plist" "$OUT/partial.plist" "$APP/Info.plist" <<'PY'
import plistlib, sys
base = plistlib.load(open(sys.argv[1], 'rb'))
base.update(plistlib.load(open(sys.argv[2], 'rb')))
plistlib.dump(base, open(sys.argv[3], 'wb'), fmt=plistlib.FMT_BINARY)
PY
printf 'APPL????' > "$APP/PkgInfo"

echo "• Signing and packaging"
codesign --force --sign - "$APP" >/dev/null 2>&1
(cd "$OUT" && ditto -c -k --norsrc --noextattr --keepParent Payload "$ROOT/build/HarborDiag.ipa")
rm -rf "$OUT"
echo "✓ $ROOT/build/HarborDiag.ipa"
