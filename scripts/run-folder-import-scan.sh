#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DAEMON_ENV_FILE=${DAEMON_ENV_FILE:-"$PROJECT_DIR/config/daemon.env"}

if [[ ! -f "$DAEMON_ENV_FILE" ]]; then
  printf 'Daemon env file not found: %s\n' "$DAEMON_ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && source "$DAEMON_ENV_FILE" && set +a

: "${PHOTO_IMPORT_DIR:?PHOTO_IMPORT_DIR must be set in $DAEMON_ENV_FILE}"
: "${IMPORTER_SCRIPT:?IMPORTER_SCRIPT must be set in $DAEMON_ENV_FILE}"

LOG_FILE=${LOG_FILE:-"$PROJECT_DIR/data/import-daemon.log"}
LOCK_FILE=${LOCK_FILE:-"$PROJECT_DIR/data/import-daemon.lock"}

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf '%s another import scan is already running\n' "$(date -Is)" >>"$LOG_FILE"
  exit 0
fi

{
  printf '%s starting import scan for %s\n' "$(date -Is)" "$PHOTO_IMPORT_DIR"
  "$IMPORTER_SCRIPT" --env-file "${IMPORTER_ENV_FILE:-$PROJECT_DIR/config/importer.env}" "$PHOTO_IMPORT_DIR"
  printf '%s import scan finished\n' "$(date -Is)"
} >>"$LOG_FILE" 2>&1
