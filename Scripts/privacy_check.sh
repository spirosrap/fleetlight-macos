#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

patterns=(
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9_]{20,}'
  'sk-[A-Za-z0-9_-]{20,}'
  '(^|[^0-9])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  '(^|[^0-9])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  '(^|[^0-9])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  '\.ts\.net'
)

failed=0
for pattern in "${patterns[@]}"; do
  matches=$(rg -l --hidden --glob '!.git/**' --glob '!**/.build/**' --glob '!Scripts/privacy_check.sh' -e "$pattern" . || true)
  if [[ -n "$matches" ]]; then
    print -u2 "Privacy check failed; prohibited content matched in:"
    print -u2 "$matches"
    failed=1
  fi
done

path_matches=$(rg -n --hidden --glob '!.git/**' --glob '!**/.build/**' --glob '!Scripts/privacy_check.sh' -e '/(Users|home)/[A-Za-z0-9._-]+' . \
  | rg -v '/(Users|home)/(example|user)(/|[^A-Za-z0-9._-]|$)' || true)
if [[ -n "$path_matches" ]]; then
  print -u2 "Privacy check failed; a personal absolute home path was found:"
  print -u2 "$path_matches"
  failed=1
fi

if [[ -n "${FLEETLIGHT_PRIVACY_DENYLIST:-}" ]]; then
  while IFS= read -r term; do
    [[ -z "$term" ]] && continue
    matches=$(rg -l -F -i --hidden --glob '!.git/**' --glob '!**/.build/**' --glob '!Scripts/privacy_check.sh' -- "$term" . || true)
    if [[ -n "$matches" ]]; then
      print -u2 "Privacy check failed; an external denylist term matched in:"
      print -u2 "$matches"
      failed=1
    fi
  done <<< "$FLEETLIGHT_PRIVACY_DENYLIST"
fi

if [[ $failed -ne 0 ]]; then
  exit 1
fi

echo "Privacy check passed."
