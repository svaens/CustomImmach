#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CERT_DIR="$PROJECT_DIR/config/nginx/certs"
CRT_FILE="$CERT_DIR/tls.crt"
KEY_FILE="$CERT_DIR/tls.key"
COMMON_NAME=${1:-localhost}

mkdir -p "$CERT_DIR"

openssl req \
  -x509 \
  -nodes \
  -days 825 \
  -newkey rsa:4096 \
  -keyout "$KEY_FILE" \
  -out "$CRT_FILE" \
  -subj "/CN=$COMMON_NAME"

chmod 0600 "$KEY_FILE"
chmod 0644 "$CRT_FILE"

printf 'Wrote %s and %s for CN=%s\n' "$CRT_FILE" "$KEY_FILE" "$COMMON_NAME"
