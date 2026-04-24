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

PRIMARY_NAME=${1:-$DEFAULT_PRIMARY_NAME}
if [[ $# -gt 0 ]]; then
  shift
fi

EXTRA_NAMES=("$@")
if [[ ${#EXTRA_NAMES[@]} -eq 0 && "$PRIMARY_NAME" != "localhost" ]]; then
  EXTRA_NAMES=("localhost")
fi

ALT_NAMES=("DNS:$PRIMARY_NAME")
for name in "${EXTRA_NAMES[@]}"; do
  ALT_NAMES+=("DNS:$name")
done

if [[ "$PRIMARY_NAME" != "localhost" ]]; then
  ALT_NAMES+=("DNS:localhost")
fi
ALT_NAMES+=("IP:127.0.0.1")

mkdir -p "$CERT_DIR"

alt_names_section() {
  local dns_index=1
  local ip_index=1
  local entry value

  for entry in "${ALT_NAMES[@]}"; do
    case "$entry" in
      DNS:*)
        value=${entry#DNS:}
        printf 'DNS.%s = %s\n' "$dns_index" "$value"
        dns_index=$((dns_index + 1))
        ;;
      IP:*)
        value=${entry#IP:}
        printf 'IP.%s = %s\n' "$ip_index" "$value"
        ip_index=$((ip_index + 1))
        ;;
      *)
        printf 'Unsupported SAN entry: %s\n' "$entry" >&2
        exit 1
        ;;
    esac
  done
}

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
  -out "$SERVER_CERT" -days 825 -sha256 -extensions req_ext -extfile "$OPENSSL_CONFIG"

chmod 0600 "$CA_KEY" "$SERVER_KEY"
chmod 0644 "$CA_CERT" "$SERVER_CERT"
rm -f "$SERVER_CSR" "$OPENSSL_CONFIG" "$CA_OPENSSL_CONFIG" "$CERT_DIR/ca.srl"

printf 'Generated certificate material in %s\n' "$CERT_DIR"
printf 'Files:\n'
printf '  %s\n' "ca.crt" "ca.key" "server.crt" "server.key"
