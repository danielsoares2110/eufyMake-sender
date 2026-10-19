#!/bin/bash
# Build "EufyMake Sender.app" with swiftc + clang + actool (no Xcode project needed).
# Run from the project root: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="EufyMake Sender.app"
BIN="$APP/Contents/MacOS/EufyMakeSender"
DEFAULT_ICON='/Users/danny/Library/CloudStorage/OneDrive-LibertyUniversity/Danny'"'"'s data/App icons/EufyMake Sender.icon'
ICON_SRC="${ICON_SRC:-$DEFAULT_ICON}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

echo ">> compiling CryptoShim.m"
xcrun --sdk macosx clang -c Sources/CryptoShim.m -o build/CryptoShim.o -arch arm64 -mmacosx-version-min=26.0

echo ">> compiling Swift sources"
xcrun --sdk macosx swiftc -O \
  -import-objc-header Sources/CryptoShim.h \
  Sources/Pppp.swift Sources/AnkerMQTT.swift Sources/AnkerAPI.swift Sources/H264Decoder.swift \
  Sources/PrinterHub.swift Sources/LoginWindow.swift Sources/AppSettings.swift Sources/ContentView.swift Sources/Main.swift \
  build/CryptoShim.o \
  -target arm64-apple-macos26.0 \
  -o "$BIN"

if [ -e "$ICON_SRC" ]; then
  echo ">> compiling app icon (Icon Composer .icon -> icns + Assets.car)"
  rm -rf build/icon-out && mkdir -p build/icon-out
  xcrun actool --compile build/icon-out \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon "EufyMake Sender" --output-partial-info-plist build/icon-out/partial.plist \
    "$ICON_SRC" >/dev/null
  cp "build/icon-out/EufyMake Sender.icns" "$APP/Contents/Resources/EufyMake Sender.icns"
  cp build/icon-out/Assets.car "$APP/Contents/Resources/Assets.car"
else
  echo "!! icon not found at: $ICON_SRC (building without an app icon)"
fi

cp Info.plist "$APP/Contents/Info.plist"

echo ">> ad-hoc signing"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built $APP — run with: open '$APP'"
