#!/usr/bin/env bash
set -Eeuo pipefail

# Run from any directory; all Compose paths are relative to the project root.
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BACKUP_DIR="$PROJECT_DIR/bak"
PARTIAL_BACKUP=""

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$PARTIAL_BACKUP" && -f "$PARTIAL_BACKUP" ]]; then
    rm -f -- "$PARTIAL_BACKUP"
  fi
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || fail 'Docker is not installed.'
command -v gzip >/dev/null 2>&1 || fail 'gzip is not installed.'
command -v flock >/dev/null 2>&1 || fail 'flock is not installed.'
[[ -f "$PROJECT_DIR/.env" ]] || fail "Missing $PROJECT_DIR/.env"

cd "$PROJECT_DIR"
docker compose config --quiet || fail 'Docker Compose configuration is invalid.'
UP_HELP=$(docker compose up --help) || fail 'Could not inspect Docker Compose capabilities.'
grep -q -- '--wait-timeout' <<<"$UP_HELP" ||
  fail 'Docker Compose is too old for the health-checked restart used by this script.'

# This repository uses the moving major-version tag. A pinned tag would pull
# the same version again, so reject it before taking the application offline.
IMAGES=$(docker compose config --images) || fail 'Could not inspect Compose images.'
grep -Fxq 'ghcr.io/immich-app/immich-server:v3' <<<"$IMAGES" ||
  fail 'Immich server image is not tagged :v3; update IMMICH_VERSION before running this script.'
grep -Fxq 'ghcr.io/immich-app/immich-machine-learning:v3' <<<"$IMAGES" ||
  fail 'Machine learning image is not tagged :v3; update IMMICH_VERSION before running this script.'

umask 077
mkdir -p -- "$BACKUP_DIR" || fail "Cannot create $BACKUP_DIR"
exec 9>"$BACKUP_DIR/.upgrade.lock"
flock -n 9 || fail 'Another backup and upgrade is already running.'

printf 'Stopping Immich services; PostgreSQL will remain available.\n'
docker compose stop nginx immich-server immich-machine-learning redis ||
  fail 'Could not stop Immich services. No update was attempted.'
docker compose up -d database ||
  fail 'Could not start PostgreSQL. No update was attempted.'

ready=0
for ((attempt = 1; attempt <= 30; attempt++)); do
  if docker compose exec -T database sh -c \
    'pg_isready -q --dbname="$POSTGRES_DB" --username="$POSTGRES_USER"'; then
    ready=1
    break
  fi
  sleep 2
done
[[ "$ready" -eq 1 ]] || fail 'PostgreSQL was not ready after 60 seconds. No update was attempted.'

timestamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_DIR/immich-db-$timestamp-$$.sql.gz"
PARTIAL_BACKUP=$(mktemp "$BACKUP_DIR/.immich-db-$timestamp-XXXXXX.part") ||
  fail "Cannot create a temporary backup in $BACKUP_DIR"

printf 'Creating database dump...\n'
if ! docker compose exec -T database sh -c \
  'exec pg_dump --clean --if-exists --dbname="$POSTGRES_DB" --username="$POSTGRES_USER"' \
  | gzip >"$PARTIAL_BACKUP"; then
  fail 'Database dump failed. No update was attempted; Immich services remain stopped.'
fi

if [[ ! -s "$PARTIAL_BACKUP" ]] || ! gzip -t "$PARTIAL_BACKUP"; then
  fail 'Database dump is empty or failed gzip verification. No update was attempted; Immich services remain stopped.'
fi

mv -- "$PARTIAL_BACKUP" "$backup" || fail 'Could not save verified backup. No update was attempted.'
PARTIAL_BACKUP=""
printf 'Verified database backup: %s\n' "$backup"

printf 'Pulling Immich v3 images...\n'
docker compose pull immich-server immich-machine-learning ||
  fail "Image pull failed. Backup is at $backup; Immich services remain stopped."

printf 'Starting the updated stack...\n'
docker compose up -d --wait --wait-timeout 600 ||
  fail "Immich did not start cleanly. Backup is at $backup; inspect 'docker compose ps' and 'docker compose logs'."

printf 'Upgrade complete. Database backup: %s\n' "$backup"
