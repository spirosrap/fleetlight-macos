#!/bin/zsh
set -euo pipefail

APP_NAME="Fleetlight"

ax_panel_count() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Fleetlight"
    set panelCount to 0
    repeat with candidate in windows
      try
        set dimensions to size of candidate
        set panelWidth to item 1 of dimensions
        set panelHeight to item 2 of dimensions
        -- SwiftUI can resize the same MenuBarExtra popover across macOS releases,
        -- display scales, and accessibility text sizes. Keep this range specific
        -- to Fleetlight's panel without requiring one exact rendered geometry.
        if panelWidth ≥ 390 and panelWidth ≤ 520 and panelHeight ≥ 600 and panelHeight ≤ 900 then
          set panelCount to panelCount + 1
        end if
      end try
    end repeat
    return panelCount
  end tell
end tell
APPLESCRIPT
}

click_status_item() {
  osascript <<'APPLESCRIPT' >/dev/null
tell application "System Events"
  tell process "Fleetlight"
    repeat with candidateBar in menu bars
      repeat with candidateItem in menu bar items of candidateBar
        try
          if (description of candidateItem as text) is "status menu" and ¬
              (name of candidateItem as text) starts with "Fleetlight" then
            click candidateItem
            return
          end if
        end try
      end repeat
    end repeat
    error "Fleetlight status item was not found"
  end tell
end tell
APPLESCRIPT
}

onscreen_panel_count() {
  /usr/bin/swift - "$APP_NAME" <<'SWIFT'
import CoreGraphics
import Foundation

let owner = CommandLine.arguments[1]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let rows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let count = rows.filter { row in
    guard row[kCGWindowOwnerName as String] as? String == owner,
          let layer = row[kCGWindowLayer as String] as? Int,
          let bounds = row[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double else {
        return false
    }
    return layer >= 100 && width >= 390 && width <= 520 && height >= 600 && height <= 900
}.count
print(count)
SWIFT
}

wait_for_ax_panel_count() {
  local expected="$1"

  for (( attempt = 1; attempt <= 30; attempt++ )); do
    [[ "$(ax_panel_count)" == "$expected" ]] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_onscreen_panel_count() {
  local expected="$1"

  for (( attempt = 1; attempt <= 3; attempt++ )); do
    [[ "$(onscreen_panel_count)" == "$expected" ]] && return 0
    sleep 0.15
  done
  return 1
}

if ! pgrep -x "$APP_NAME" >/dev/null; then
  print -u2 "$APP_NAME is not running"
  exit 1
fi

# Normalize both a visible panel and the stale Accessibility-only ghost state.
if [[ "$(ax_panel_count)" != "0" || "$(onscreen_panel_count)" != "0" ]]; then
  click_status_item
fi

if ! wait_for_ax_panel_count 0 || ! wait_for_onscreen_panel_count 0; then
  print -u2 "Could not close the existing Fleetlight panel"
  exit 1
fi

for cycle in 1 2; do
  click_status_item
  # CoreGraphics is the visibility source of truth. Some macOS builds render
  # MenuBarExtra popovers on screen without exposing them as AX windows.
  if ! wait_for_onscreen_panel_count 1; then
    print -u2 "Fleetlight panel did not render on screen during open cycle $cycle"
    exit 1
  fi

  click_status_item
  if ! wait_for_onscreen_panel_count 0; then
    print -u2 "Fleetlight panel did not close during cycle $cycle"
    exit 1
  fi
done

echo "Fleetlight menu panel rendered and toggled correctly twice"
