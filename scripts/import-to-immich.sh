#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  import-to-immich.sh [options] SOURCE_DIR

Options:
  --env-file PATH        Importer environment file to load
  --album-name NAME      Put all uploaded assets into a single album
  --no-auto-album        Do not auto-create albums from folder names
  --delete               Delete local files after successful upload
  --dry-run              Show what would be uploaded without uploading
  -h, --help             Show this help
EOF
}

require_cmd() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

extract_url_host() {
  local url=$1
  local authority host

  authority=${url#*://}
  authority=${authority%%/*}

  if [[ "$authority" == \[* ]]; then
    host=${authority%%]*}
    printf '%s\n' "${host#[}"
    return
  fi

  printf '%s\n' "${authority%%:*}"
}

resolve_host_ipv4() {
  local host=$1
  getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

configure_https_trust() {
  if [[ "$IMMICH_INSTANCE_URL" =~ ^https:// ]]; then
    if [[ -f "$LOCAL_CA_CERT" ]]; then
      CLI_MOUNT_ARGS+=(-v "$LOCAL_CA_CERT:/usr/local/share/ca-certificates/immach-local-ca.crt:ro")
      CLI_ENV_ARGS+=(-e NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/immach-local-ca.crt)
    fi
  fi
}

realpath_fallback() {
  local input=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input"
    return
  fi

  local dir base
  dir=$(cd "$(dirname "$input")" && pwd)
  base=$(basename "$input")
  printf '%s/%s\n' "$dir" "$base"
}

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEFAULT_ENV_FILE="$PROJECT_DIR/config/importer.env"
LOCAL_CA_CERT="$PROJECT_DIR/config/nginx/certs/ca.crt"
ENV_FILE="$DEFAULT_ENV_FILE"
SOURCE_DIR=""
ALBUM_NAME=""
AUTO_ALBUM=1
DELETE_AFTER_UPLOAD=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE=$2
      shift 2
      ;;
    --album-name)
      ALBUM_NAME=$2
      shift 2
      ;;
    --no-auto-album)
      AUTO_ALBUM=0
      shift
      ;;
    --delete)
      DELETE_AFTER_UPLOAD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
    *)
      SOURCE_DIR=$1
      shift
      ;;
  esac
done

if [[ -z "$SOURCE_DIR" ]]; then
  usage >&2
  exit 1
fi

require_cmd docker
require_cmd exiftool

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a && source "$ENV_FILE" && set +a
fi

: "${IMMICH_CLI_IMAGE:=ghcr.io/immich-app/immich-cli:latest}"
: "${IMMICH_INSTANCE_URL:=http://localhost:2283/api}"

if [[ -z "${IMMICH_API_KEY:-}" ]]; then
  printf 'IMMICH_API_KEY is not set. Put it in %s or export it first.\n' "$ENV_FILE" >&2
  exit 1
fi

CLI_INSTANCE_URL="$IMMICH_INSTANCE_URL"
DOCKER_RUN_ARGS=(run --rm)
CLI_ENV_ARGS=(-e IMMICH_API_KEY)
CLI_MOUNT_ARGS=()
CLI_INSTANCE_HOST=$(extract_url_host "$CLI_INSTANCE_URL")

# When the CLI runs in Docker, localhost refers to the CLI container itself.
# Rewrite localhost-style URLs to the host gateway so local Immich installs work.
if [[ "$CLI_INSTANCE_HOST" =~ ^(localhost|127\.0\.0\.1|::1)$ ]]; then
  CLI_INSTANCE_URL="${CLI_INSTANCE_URL/localhost/host.docker.internal}"
  CLI_INSTANCE_URL="${CLI_INSTANCE_URL/127.0.0.1/host.docker.internal}"
  CLI_INSTANCE_URL="${CLI_INSTANCE_URL/\[::1\]/host.docker.internal}"
  CLI_INSTANCE_URL="${CLI_INSTANCE_URL/::1/host.docker.internal}"
  DOCKER_RUN_ARGS+=(--add-host host.docker.internal:host-gateway)
elif [[ ! "$CLI_INSTANCE_HOST" =~ ^[0-9.]+$ ]]; then
  # Containers often do not inherit mDNS or host /etc/hosts entries. If the host
  # machine can resolve the configured name, pin that mapping into the CLI container.
  CLI_INSTANCE_IP=$(resolve_host_ipv4 "$CLI_INSTANCE_HOST" || true)
  if [[ -n "$CLI_INSTANCE_IP" ]]; then
    DOCKER_RUN_ARGS+=(--add-host "$CLI_INSTANCE_HOST:$CLI_INSTANCE_IP")
  fi
fi

configure_https_trust

SOURCE_DIR=$(realpath_fallback "$SOURCE_DIR")
if [[ ! -d "$SOURCE_DIR" ]]; then
  printf 'Source directory does not exist: %s\n' "$SOURCE_DIR" >&2
  exit 1
fi

printf 'Repairing missing timestamps in %s\n' "$SOURCE_DIR"
if ! exiftool \
  -m \
  -overwrite_original_in_place \
  -P \
  -r \
  -if 'not $DateTimeOriginal' \
  '-DateTimeOriginal<FileModifyDate' \
  -if 'not $CreateDate' \
  '-CreateDate<FileModifyDate' \
  "$SOURCE_DIR"; then
  printf 'exiftool reported errors while repairing metadata; continuing with upload of remaining files\n' >&2
fi

UPLOAD_ARGS=(upload --recursive)

if [[ "${IMMICH_INCLUDE_HIDDEN:-false}" == "true" ]]; then
  UPLOAD_ARGS+=(--include-hidden)
fi

if [[ "${AUTO_ALBUM}" -eq 1 && "${IMMICH_AUTO_CREATE_ALBUM:-true}" == "true" ]]; then
  UPLOAD_ARGS+=(--album)
fi

if [[ -n "$ALBUM_NAME" ]]; then
  UPLOAD_ARGS+=(--album-name "$ALBUM_NAME")
fi

if [[ -n "${IMMICH_UPLOAD_CONCURRENCY:-}" ]]; then
  UPLOAD_ARGS+=(--concurrency "$IMMICH_UPLOAD_CONCURRENCY")
fi

if [[ "$DELETE_AFTER_UPLOAD" -eq 1 ]]; then
  UPLOAD_ARGS+=(--delete)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  UPLOAD_ARGS+=(--dry-run)
fi

if [[ -n "${IMMICH_IGNORE_PATTERNS:-}" ]]; then
  # shellcheck disable=SC2206
  IGNORE_PATTERNS=(${IMMICH_IGNORE_PATTERNS})
  for pattern in "${IGNORE_PATTERNS[@]}"; do
    UPLOAD_ARGS+=(--ignore "$pattern")
  done
fi

printf 'Uploading from %s to %s\n' "$SOURCE_DIR" "$IMMICH_INSTANCE_URL"
docker "${DOCKER_RUN_ARGS[@]}" \
  -v "$SOURCE_DIR:$SOURCE_DIR:ro" \
  "${CLI_MOUNT_ARGS[@]}" \
  -e IMMICH_INSTANCE_URL="$CLI_INSTANCE_URL" \
  "${CLI_ENV_ARGS[@]}" \
  "$IMMICH_CLI_IMAGE" \
  "${UPLOAD_ARGS[@]}" \
  "$SOURCE_DIR"
