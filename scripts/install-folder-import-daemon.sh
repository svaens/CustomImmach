#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo install-folder-import-daemon.sh --import-dir DIR --server-url URL --api-key KEY [options]

Options:
  --project-dir DIR         Project directory
  --import-dir DIR          Folder to scan and upload
  --server-url URL          Immich API URL, for example http://localhost:2283/api
  --api-key KEY             Immich API key
  --run-user USER           Linux user that should run uploads
  --interval-minutes N      Scan interval in minutes
  --unit-name NAME          systemd unit base name
  -h, --help                Show this help
EOF
}

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMPORT_DIR=""
SERVER_URL=""
API_KEY=""
RUN_USER=${SUDO_USER:-${USER}}
INTERVAL_MINUTES=10
UNIT_NAME=immich-folder-import

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)
      PROJECT_DIR=$2
      shift 2
      ;;
    --import-dir)
      IMPORT_DIR=$2
      shift 2
      ;;
    --server-url)
      SERVER_URL=$2
      shift 2
      ;;
    --api-key)
      API_KEY=$2
      shift 2
      ;;
    --run-user)
      RUN_USER=$2
      shift 2
      ;;
    --interval-minutes)
      INTERVAL_MINUTES=$2
      shift 2
      ;;
    --unit-name)
      UNIT_NAME=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  printf 'Run this installer as root, for example with sudo.\n' >&2
  exit 1
fi

if [[ -z "$IMPORT_DIR" || -z "$SERVER_URL" || -z "$API_KEY" ]]; then
  usage >&2
  exit 1
fi

if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  printf 'Run user does not exist: %s\n' "$RUN_USER" >&2
  exit 1
fi

PROJECT_DIR=$(realpath "$PROJECT_DIR")
IMPORT_DIR=$(realpath "$IMPORT_DIR")
DAEMON_ENV_FILE="$PROJECT_DIR/config/daemon.env"
IMPORTER_ENV_FILE="$PROJECT_DIR/config/importer.env"

install -d -m 0755 "$PROJECT_DIR/config" "$PROJECT_DIR/data"

cat >"$IMPORTER_ENV_FILE" <<EOF
IMMICH_CLI_IMAGE=ghcr.io/immich-app/immich-cli:latest
IMMICH_INSTANCE_URL=$SERVER_URL
IMMICH_API_KEY=$API_KEY
IMMICH_UPLOAD_CONCURRENCY=5
IMMICH_AUTO_CREATE_ALBUM=true
IMMICH_INCLUDE_HIDDEN=false
IMMICH_IGNORE_PATTERNS=
EOF

cat >"$DAEMON_ENV_FILE" <<EOF
PHOTO_IMPORT_DIR=$IMPORT_DIR
IMPORTER_ENV_FILE=$IMPORTER_ENV_FILE
IMPORTER_SCRIPT=$PROJECT_DIR/scripts/import-to-immich.sh
LOG_FILE=$PROJECT_DIR/data/import-daemon.log
LOCK_FILE=$PROJECT_DIR/data/import-daemon.lock
EOF

chown "$RUN_USER:$RUN_USER" "$IMPORTER_ENV_FILE" "$DAEMON_ENV_FILE"
chmod 0600 "$IMPORTER_ENV_FILE" "$DAEMON_ENV_FILE"

SERVICE_FILE="/etc/systemd/system/$UNIT_NAME.service"
TIMER_FILE="/etc/systemd/system/$UNIT_NAME.timer"

sed \
  -e "s|__RUN_USER__|$RUN_USER|g" \
  -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
  -e "s|__DAEMON_ENV_FILE__|$DAEMON_ENV_FILE|g" \
  "$PROJECT_DIR/systemd/immich-folder-import.service.template" >"$SERVICE_FILE"

sed \
  -e "s|__INTERVAL_MINUTES__|$INTERVAL_MINUTES|g" \
  -e "s|__UNIT_NAME__|$UNIT_NAME|g" \
  "$PROJECT_DIR/systemd/immich-folder-import.timer.template" >"$TIMER_FILE"

chmod 0644 "$SERVICE_FILE" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable --now "$UNIT_NAME.timer"

printf 'Installed %s.timer for %s scanning %s every %s minutes.\n' \
  "$UNIT_NAME" "$RUN_USER" "$IMPORT_DIR" "$INTERVAL_MINUTES"
