#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Fleetlight.app"
CONTENTS="$APP/Contents"
ICONSET="$ROOT/.build/Fleetlight.iconset"
IDENTITY="${APP_IDENTITY:--}"

cd "$ROOT"
swift build -c release

rm -rf "$APP" "$ICONSET"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$ICONSET"
cp "$ROOT/.build/release/Fleetlight" "$CONTENTS/MacOS/Fleetlight"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"

swift "$ROOT/Scripts/make_icon.swift" "$ROOT/.build/Fleetlight-1024.png"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ROOT/.build/Fleetlight-1024.png" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/Fleetlight.icns"

if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  print -u2 "Code-signing identity not found: $IDENTITY"
  exit 1
fi

codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"
