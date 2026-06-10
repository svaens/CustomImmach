#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo uninstall-folder-import-daemon.sh [options]

Options:
  --project-dir DIR         Project directory
  --unit-name NAME          systemd unit base name
  --purge                   Remove generated env/log/lock files from the project
  -h, --help                Show this help
EOF
}

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UNIT_NAME=immich-folder-import
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)
      PROJECT_DIR=$2
      shift 2
      ;;
    --unit-name)
      UNIT_NAME=$2
      shift 2
      ;;
    --purge)
      PURGE=1
      shift
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
  printf 'Run this uninstaller as root, for example with sudo.\n' >&2
  exit 1
fi

PROJECT_DIR=$(realpath "$PROJECT_DIR")
SERVICE_FILE="/etc/systemd/system/$UNIT_NAME.service"
TIMER_FILE="/etc/systemd/system/$UNIT_NAME.timer"

systemctl disable --now "$UNIT_NAME.timer" 2>/dev/null || true
systemctl stop "$UNIT_NAME.service" 2>/dev/null || true

rm -f "$SERVICE_FILE" "$TIMER_FILE"

systemctl daemon-reload
systemctl reset-failed "$UNIT_NAME.service" "$UNIT_NAME.timer" 2>/dev/null || true

if [[ "$PURGE" -eq 1 ]]; then
  rm -f \
    "$PROJECT_DIR/config/daemon.env" \
    "$PROJECT_DIR/config/importer.env" \
    "$PROJECT_DIR/data/import-daemon.log" \
    "$PROJECT_DIR/data/import-daemon.lock"
fi

printf 'Uninstalled %s service and timer.\n' "$UNIT_NAME"
if [[ "$PURGE" -eq 1 ]]; then
  printf 'Purged generated config and log files from %s.\n' "$PROJECT_DIR"
fi
