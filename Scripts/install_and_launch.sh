#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE_APP="$ROOT/dist/Fleetlight.app"
TARGET_APP="/Applications/Fleetlight.app"

"$ROOT/Scripts/build_app.sh"

pkill -x Fleetlight 2>/dev/null || true
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
if ! open "$TARGET_APP"; then
  # LaunchServices can briefly retain the just-terminated bundle registration.
  sleep 2
  open "$TARGET_APP"
fi

echo "$TARGET_APP"
