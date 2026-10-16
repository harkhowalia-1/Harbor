#!/bin/bash
# Builds the libraries Harbor injects into every converted app:
#   libHarborRuntime.dylib   Mac Catalyst (UIKit) — device, screen, keychain, motion, touch, keymap
#   libHarborAppKit.dylib    macOS (AppKit)       — key monitor, window shape, pointer
#   libHarborWebMedia.dylib  Mac Catalyst         — camera, microphone and recording for web views
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/Runtime}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$OUT"

COMMON=(-isysroot "$SDK" -fobjc-arc -fmodules -O2 -Wall -Wno-unused-function -dynamiclib)

xcrun clang -target arm64-apple-ios15.0-macabi "${COMMON[@]}" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -install_name @executable_path/Frameworks/libHarborRuntime.dylib \
    -framework UIKit -framework CoreMotion -framework GameController -framework Security \
    -o "$OUT/libHarborRuntime.dylib" "$ROOT"/Runtime/*.m

# The page script is compiled in as a string.
{ printf 'static NSString *const HBWebMediaScript = @R"HBJS('; cat "$ROOT/Runtime/WebMedia/HBWebMedia.js"; printf ')HBJS";\n'; } \
    > "$OUT/HBWebMediaScript.h"
xcrun clang -target arm64-apple-ios15.0-macabi "${COMMON[@]}" -I "$OUT" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -install_name @executable_path/Frameworks/libHarborWebMedia.dylib \
    -framework UIKit -framework WebKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework UniformTypeIdentifiers \
    -o "$OUT/libHarborWebMedia.dylib" "$ROOT/Runtime/WebMedia/HBWebMedia.m"
rm "$OUT/HBWebMediaScript.h"

xcrun clang -target arm64-apple-macos11.0 "${COMMON[@]}" \
    -install_name @executable_path/Frameworks/libHarborAppKit.dylib \
    -framework AppKit \
    -o "$OUT/libHarborAppKit.dylib" "$ROOT/Runtime/AppKit/HBAppKitBridge.m"

codesign --force --sign - "$OUT/libHarborRuntime.dylib" "$OUT/libHarborAppKit.dylib" "$OUT/libHarborWebMedia.dylib" 2>/dev/null
echo "✓ Runtime built in $OUT"
