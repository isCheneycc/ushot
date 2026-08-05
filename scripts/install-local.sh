#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="${1:-$PROJECT_ROOT/build/release/artifacts/UshotApp.app}"
DESTINATION_APP="/Applications/UshotApp.app"
APP_NAME="UshotApp"
ALLOW_SIGNING_IDENTITY_MIGRATION="${ALLOW_SIGNING_IDENTITY_MIGRATION:-NO}"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "error: Signed app bundle not found at $SOURCE_APP. Run scripts/build-release.sh first." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"
SOURCE_SIGNATURE="$(codesign --display --verbose=4 "$SOURCE_APP" 2>&1)"
SOURCE_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$SOURCE_SIGNATURE")"
SOURCE_REQUIREMENT="$(codesign --display --requirements - "$SOURCE_APP" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$SOURCE_TEAM" || "$SOURCE_TEAM" == "not set" ]]; then
  echo "error: Refusing to install an app without a stable TeamIdentifier." >&2
  exit 1
fi
if grep -q '^Signature=adhoc$' <<<"$SOURCE_SIGNATURE"; then
  echo "error: Refusing to install an ad-hoc build because it would invalidate macOS privacy permissions." >&2
  exit 1
fi
if [[ -z "$SOURCE_REQUIREMENT" ]]; then
  echo "error: Refusing to install an app without a designated requirement." >&2
  exit 1
fi

if [[ -d "$DESTINATION_APP" ]]; then
  DESTINATION_REQUIREMENT="$(codesign --display --requirements - "$DESTINATION_APP" 2>&1 | sed -n 's/^designated => //p' || true)"
  IDENTITIES_COMPATIBLE=NO
  if [[ -n "$DESTINATION_REQUIREMENT" ]] \
      && codesign --verify --strict "-R=$DESTINATION_REQUIREMENT" "$SOURCE_APP" >/dev/null 2>&1 \
      && codesign --verify --strict "-R=$SOURCE_REQUIREMENT" "$DESTINATION_APP" >/dev/null 2>&1; then
    IDENTITIES_COMPATIBLE=YES
  fi
  if [[ "$IDENTITIES_COMPATIBLE" != "YES" && "$ALLOW_SIGNING_IDENTITY_MIGRATION" != "YES" ]]; then
    echo "error: Installed and replacement apps do not have compatible signing identities." >&2
    echo "error: If this is the intentional one-time migration from ad-hoc to Apple Development signing, rerun with ALLOW_SIGNING_IDENTITY_MIGRATION=YES." >&2
    exit 1
  fi
fi

RUNNING_PIDS="$(pgrep -f "^$DESTINATION_APP/Contents/MacOS/$APP_NAME$" || true)"
if [[ -n "$RUNNING_PIDS" ]]; then
  kill -TERM $RUNNING_PIDS
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    STILL_RUNNING=NO
    for PID in $RUNNING_PIDS; do
      if kill -0 "$PID" 2>/dev/null; then STILL_RUNNING=YES; fi
    done
    if [[ "$STILL_RUNNING" == "NO" ]]; then break; fi
    sleep 0.2
  done
  if [[ "$STILL_RUNNING" == "YES" ]]; then
    echo "error: Installed UshotApp did not quit after SIGTERM: $RUNNING_PIDS" >&2
    exit 1
  fi
fi

BACKUP_APP=""
if [[ -d "$DESTINATION_APP" ]]; then
  TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
  BACKUP_APP="$HOME/.Trash/UshotApp-before-signed-install-$TIMESTAMP.app"
  if [[ -e "$BACKUP_APP" ]]; then
    echo "error: Backup destination already exists: $BACKUP_APP" >&2
    exit 1
  fi
  mv "$DESTINATION_APP" "$BACKUP_APP"
fi

/usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
cmp "$SOURCE_APP/Contents/MacOS/$APP_NAME" "$DESTINATION_APP/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"
open -na "$DESTINATION_APP"

NEW_PID=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  NEW_PID="$(pgrep -f "^$DESTINATION_APP/Contents/MacOS/$APP_NAME$" || true)"
  if [[ -n "$NEW_PID" ]]; then break; fi
  sleep 0.25
done
if [[ -z "$NEW_PID" ]]; then
  echo "error: Installed app did not launch. Recover the previous bundle from: $BACKUP_APP" >&2
  exit 1
fi

echo "Installed signed UshotApp: $DESTINATION_APP"
echo "Team identifier: $SOURCE_TEAM"
echo "Designated requirement: $SOURCE_REQUIREMENT"
echo "Running PID: $NEW_PID"
if [[ -n "$BACKUP_APP" ]]; then echo "Recoverable backup: $BACKUP_APP"; fi
