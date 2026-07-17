#!/bin/zsh
set -euo pipefail

TAILSCALE_BIN="${TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
FEED_TARGET="${FLEETLIGHT_MOBILE_TARGET:-http://127.0.0.1:8787}"
SERVE_PATH="${FLEETLIGHT_MOBILE_PATH:-/fleetlight}"

if [[ ! -x "$TAILSCALE_BIN" ]]; then
  print -u2 "Tailscale CLI not found: $TAILSCALE_BIN"
  exit 1
fi

if ! /usr/bin/curl --fail --silent --show-error --max-time 3 "$FEED_TARGET/health" >/dev/null; then
  print -u2 "Fleetlight's local mobile feed is not ready at $FEED_TARGET. Open Fleetlight and try again."
  exit 1
fi

"$TAILSCALE_BIN" serve --bg --yes --set-path "$SERVE_PATH" "$FEED_TARGET"

dns_name=$("$TAILSCALE_BIN" status --json | plutil -extract Self.DNSName raw -o - -- -)
dns_name="${dns_name%.}"
printf 'Fleetlight mobile feed: https://%s%s/mobile-feed.json\n' "$dns_name" "$SERVE_PATH"
printf 'Fleetlight Android control: https://%s%s/control/v1 (disabled until paired in Settings)\n' "$dns_name" "$SERVE_PATH"
