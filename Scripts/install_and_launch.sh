#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE_APP="$ROOT/dist/Fleetlight.app"
TARGET_APP="/Applications/Fleetlight.app"
STAGED_APP="/Applications/.Fleetlight.installing.$$"
BACKUP_APP="/Applications/.Fleetlight.previous.$$"
LOCK_DIR="${TMPDIR:-/tmp}/app.fleetlight.install.lock"
INSTALL_SWAPPED=0
INSTALL_VERIFIED=0
LOCK_ACQUIRED=0

wait_for_exit() {
  local attempts="$1"
  local delay="$2"

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    if ! pgrep -x Fleetlight >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

stop_running_app() {
  pkill -TERM -x Fleetlight 2>/dev/null || true
  if wait_for_exit 50 0.1; then
    return 0
  fi

  pkill -KILL -x Fleetlight 2>/dev/null || true
  wait_for_exit 20 0.1
}

restore_previous_app() {
  if ! stop_running_app; then
    print -u2 "Fleetlight rollback could not stop the replacement; backup retained at $BACKUP_APP"
    return 1
  fi

  rm -rf "$TARGET_APP"
  if [[ -e "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$TARGET_APP"
    sleep 0.75
    open -n "$TARGET_APP" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local exit_code="$?"
  trap - EXIT HUP INT TERM
  set +e

  rm -rf "$STAGED_APP"
  if (( INSTALL_SWAPPED == 1 && INSTALL_VERIFIED == 0 )); then
    restore_previous_app
  elif (( INSTALL_SWAPPED == 0 )) && [[ ! -e "$TARGET_APP" && -e "$BACKUP_APP" ]]; then
    mv "$BACKUP_APP" "$TARGET_APP"
    sleep 0.75
    open -n "$TARGET_APP" >/dev/null 2>&1 || true
  elif (( INSTALL_VERIFIED == 1 )); then
    rm -rf "$BACKUP_APP"
  fi

  (( LOCK_ACQUIRED == 1 )) && rm -rf "$LOCK_DIR"
  exit "$exit_code"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    print -r -- "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  local owner_pid=""
  [[ -r "$LOCK_DIR/pid" ]] && owner_pid="$(<"$LOCK_DIR/pid")"
  if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
    print -u2 "Another Fleetlight install is already running (pid $owner_pid)"
    return 1
  fi

  rm -rf "$LOCK_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    print -u2 "Could not acquire the Fleetlight install lock"
    return 1
  fi
  LOCK_ACQUIRED=1
  print -r -- "$$" > "$LOCK_DIR/pid"
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

acquire_lock
if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 "Prebuilt Fleetlight app not found at $SOURCE_APP"
    exit 1
  fi
else
  "$ROOT/Scripts/build_app.sh"
fi

expected_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
expected_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"

if ! stop_running_app; then
  print -u2 "Fleetlight did not terminate cleanly; the existing app was left untouched"
  exit 1
fi

# Let Control Center release the previous MenuBarExtra scene before registering
# the replacement. Reopening too early can leave a healthy process with an
# invisible, off-screen menu panel until the app is restarted again.
sleep 0.75

rm -rf "$STAGED_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -e "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$BACKUP_APP"
fi
INSTALL_SWAPPED=1
if ! mv "$STAGED_APP" "$TARGET_APP"; then
  print -u2 "Could not install Fleetlight; rolling back"
  exit 1
fi

if ! open -n "$TARGET_APP"; then
  print -u2 "Fleetlight could not launch; rolling back"
  exit 1
fi

launched_pid=""
health_ready=0
for (( attempt = 1; attempt <= 80; attempt++ )); do
  launched_pid="$(pgrep -x Fleetlight | head -1 || true)"
  if [[ -n "$launched_pid" ]] && curl --silent --fail --max-time 0.5 http://127.0.0.1:8787/health \
      | grep -Fq '"status":"ok"'; then
    health_ready=1
    break
  fi
  sleep 0.1
done

if [[ -z "$launched_pid" || "$health_ready" != "1" ]]; then
  print -u2 "Fleetlight did not become healthy; rolling back"
  exit 1
fi

installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")"

if [[ "$installed_version" != "$expected_version" || "$installed_build" != "$expected_build" ]]; then
  print -u2 "Fleetlight launched with an unexpected version; rolling back"
  exit 1
fi

sleep 0.5
if ! kill -0 "$launched_pid" 2>/dev/null; then
  print -u2 "Fleetlight exited during launch verification; rolling back"
  exit 1
fi

if [[ "${VERIFY_MENU_PANEL:-0}" == "1" ]]; then
  "$ROOT/Scripts/verify_menu_panel.sh"
fi

INSTALL_VERIFIED=1

echo "$TARGET_APP (v$installed_version build $installed_build, pid $launched_pid)"
