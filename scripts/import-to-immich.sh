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

SOURCE_DIR=$(realpath_fallback "$SOURCE_DIR")
if [[ ! -d "$SOURCE_DIR" ]]; then
  printf 'Source directory does not exist: %s\n' "$SOURCE_DIR" >&2
  exit 1
fi

printf 'Repairing missing timestamps in %s\n' "$SOURCE_DIR"
exiftool \
  -overwrite_original_in_place \
  -P \
  -r \
  -if 'not $DateTimeOriginal' \
  '-DateTimeOriginal<FileModifyDate' \
  -if 'not $CreateDate' \
  '-CreateDate<FileModifyDate' \
  "$SOURCE_DIR"

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
docker run --rm \
  -v "$SOURCE_DIR:$SOURCE_DIR:ro" \
  -e IMMICH_INSTANCE_URL \
  -e IMMICH_API_KEY \
  "$IMMICH_CLI_IMAGE" \
  "${UPLOAD_ARGS[@]}" \
  "$SOURCE_DIR"
