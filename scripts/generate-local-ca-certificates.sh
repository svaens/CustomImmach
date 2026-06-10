#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CERT_DIR="$PROJECT_DIR/config/nginx/certs"
ENV_FILE="$PROJECT_DIR/.env"

CA_KEY="$CERT_DIR/ca.key"
CA_CERT="$CERT_DIR/ca.crt"
SERVER_KEY="$CERT_DIR/server.key"
SERVER_CSR="$CERT_DIR/server.csr"
SERVER_CERT="$CERT_DIR/server.crt"
OPENSSL_CONFIG="$CERT_DIR/server-openssl.cnf"
CA_OPENSSL_CONFIG="$CERT_DIR/ca-openssl.cnf"

DEFAULT_PRIMARY_NAME=localhost
if [[ -f "$ENV_FILE" ]]; then
  DEFAULT_PRIMARY_NAME=$(awk -F= '/^PUBLIC_HOSTNAME=/{print $2}' "$ENV_FILE" | tail -n 1)
  DEFAULT_PRIMARY_NAME=${DEFAULT_PRIMARY_NAME:-localhost}
fi

DAYS_VALUE="${NGINX_CERT_DAYS:-825}"

declare -A SEEN_DNS_NAMES=()
declare -a DNS_NAMES=()
declare -a IP_NAMES=()

append_dns_name() {
  local value=$1

  [[ -n "$value" ]] || return 0

  if [[ -z "${SEEN_DNS_NAMES[$value]+x}" ]]; then
    DNS_NAMES+=("$value")
    SEEN_DNS_NAMES["$value"]=1
  fi
}

append_ip_name() {
  local value=$1

  [[ -n "$value" ]] || return 0
  IP_NAMES+=("$value")
}

set_default_alt_names() {
  local primary_name=$1
  shift || true

  append_dns_name "$primary_name"

  local extra_name
  for extra_name in "$@"; do
    append_dns_name "$extra_name"
  done

  append_dns_name "localhost"
  append_ip_name "127.0.0.1"
}

load_alt_names_from_value() {
  local alt_names_value=$1
  local old_ifs=$IFS
  IFS=','
  read -r -a alt_name_entries <<< "$alt_names_value"
  IFS=$old_ifs

  local entry trimmed
  for entry in "${alt_name_entries[@]}"; do
    trimmed=$(printf '%s' "$entry" | sed 's/^ *//; s/ *$//')

    case "$trimmed" in
      DNS:*)
        append_dns_name "${trimmed#DNS:}"
        ;;
      IP:*)
        append_ip_name "${trimmed#IP:}"
        ;;
      *)
        printf 'Unsupported SAN entry: %s\n' "$trimmed" >&2
        exit 1
        ;;
    esac
  done
}

alt_names_section() {
  local dns_index=1
  local ip_index=1
  local value

  for value in "${DNS_NAMES[@]}"; do
    printf 'DNS.%s = %s\n' "$dns_index" "$value"
    dns_index=$((dns_index + 1))
  done

  for value in "${IP_NAMES[@]}"; do
    printf 'IP.%s = %s\n' "$ip_index" "$value"
    ip_index=$((ip_index + 1))
  done
}

PRIMARY_NAME="${NGINX_CERT_HOSTNAME:-${1:-$DEFAULT_PRIMARY_NAME}}"
if [[ $# -gt 0 && -z "${NGINX_CERT_HOSTNAME:-}" ]]; then
  shift
fi

if [[ -n "${NGINX_CERT_ALT_NAMES:-}" ]]; then
  load_alt_names_from_value "${NGINX_CERT_ALT_NAMES}"
else
  EXTRA_NAMES=("$@")
  set_default_alt_names "$PRIMARY_NAME" "${EXTRA_NAMES[@]}"
fi

mkdir -p "$CERT_DIR"

cat > "$CA_OPENSSL_CONFIG" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca

[dn]
CN = Immach Local NGINX CA

[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl genrsa -out "$CA_KEY" 4096
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
  -config "$CA_OPENSSL_CONFIG" \
  -out "$CA_CERT"

openssl genrsa -out "$SERVER_KEY" 4096
{
  cat <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $PRIMARY_NAME

[req_ext]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth
keyUsage = digitalSignature,keyEncipherment

[alt_names]
EOF
  alt_names_section
} > "$OPENSSL_CONFIG"

openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$OPENSSL_CONFIG"
openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CERT" -days "$DAYS_VALUE" -sha256 -extensions req_ext -extfile "$OPENSSL_CONFIG"

chmod 0600 "$CA_KEY" "$SERVER_KEY"
chmod 0644 "$CA_CERT" "$SERVER_CERT"
rm -f "$SERVER_CSR" "$OPENSSL_CONFIG" "$CA_OPENSSL_CONFIG" "$CERT_DIR/ca.srl"

printf 'Generated certificate material in %s\n' "$CERT_DIR"
printf 'Files:\n'
printf '  %s\n' "ca.crt" "ca.key" "server.crt" "server.key"
printf '\nEnvironment overrides:\n'
printf '  %s\n' "NGINX_CERT_HOSTNAME" "NGINX_CERT_ALT_NAMES" "NGINX_CERT_DAYS"
