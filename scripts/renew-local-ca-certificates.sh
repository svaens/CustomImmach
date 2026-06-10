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

DAYS_VALUE="${NGINX_CERT_DAYS:-825}"

for required_file in "$CA_KEY" "$CA_CERT"; do
  if [[ ! -f "$required_file" ]]; then
    printf 'Missing required CA file: %s\n' "$required_file" >&2
    printf 'This renewal script preserves the existing CA and issues a new server certificate.\n' >&2
    printf 'If you need a brand-new local CA, use generate-local-ca-certificates.sh instead.\n' >&2
    exit 1
  fi
done

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

infer_hostname_from_env() {
  if [[ -f "$ENV_FILE" ]]; then
    local env_hostname
    env_hostname=$(awk -F= '/^PUBLIC_HOSTNAME=/{print $2}' "$ENV_FILE" | tail -n 1)
    env_hostname=${env_hostname:-}
    if [[ -n "$env_hostname" ]]; then
      printf '%s\n' "$env_hostname"
      return 0
    fi
  fi

  printf 'localhost\n'
}

infer_hostname_from_existing_cert() {
  if [[ -f "$SERVER_CERT" ]]; then
    local subject_line hostname_value
    subject_line=$(openssl x509 -in "$SERVER_CERT" -noout -subject -nameopt RFC2253 2>/dev/null || true)
    hostname_value=$(printf '%s\n' "$subject_line" | sed -n 's/^subject=.*CN=\([^,][^,]*\).*$/\1/p')
    if [[ -n "$hostname_value" ]]; then
      printf '%s\n' "$hostname_value"
      return 0
    fi
  fi

  infer_hostname_from_env
}

infer_alt_names_from_existing_cert() {
  if [[ -f "$SERVER_CERT" ]]; then
    local san_value
    san_value=$(openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName 2>/dev/null | sed -n '2p' | sed 's/^[[:space:]]*//')
    if [[ -n "$san_value" ]]; then
      printf '%s\n' "$san_value" | sed 's/IP Address:/IP:/g; s/, */,/g'
      return 0
    fi
  fi

  printf 'DNS:%s,DNS:localhost,IP:127.0.0.1\n' "$HOSTNAME_VALUE"
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

HOSTNAME_VALUE="${NGINX_CERT_HOSTNAME:-$(infer_hostname_from_existing_cert)}"
if [[ $# -gt 0 && -z "${NGINX_CERT_HOSTNAME:-}" ]]; then
  HOSTNAME_VALUE=$1
  shift
fi

if [[ -n "${NGINX_CERT_ALT_NAMES:-}" ]]; then
  load_alt_names_from_value "${NGINX_CERT_ALT_NAMES}"
elif [[ $# -gt 0 ]]; then
  append_dns_name "$HOSTNAME_VALUE"
  for name in "$@"; do
    append_dns_name "$name"
  done
  append_dns_name "localhost"
  append_ip_name "127.0.0.1"
else
  load_alt_names_from_value "$(infer_alt_names_from_existing_cert)"
fi

{
  cat <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $HOSTNAME_VALUE

[req_ext]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth
keyUsage = digitalSignature,keyEncipherment

[alt_names]
EOF
  alt_names_section
} > "$OPENSSL_CONFIG"

rm -f "$SERVER_KEY" "$SERVER_CERT"
openssl genrsa -out "$SERVER_KEY" 4096
openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$OPENSSL_CONFIG"
openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CERT" -days "$DAYS_VALUE" -sha256 -extensions req_ext -extfile "$OPENSSL_CONFIG"

chmod 0600 "$SERVER_KEY"
chmod 0644 "$SERVER_CERT"
rm -f "$SERVER_CSR" "$OPENSSL_CONFIG" "$CERT_DIR/ca.srl"

printf 'Renewed local HTTPS server certificate in %s\n' "$CERT_DIR"
printf 'Reused CA:\n'
printf '  %s\n' "ca.crt" "ca.key"
printf 'Replaced files:\n'
printf '  %s\n' "server.crt" "server.key"
printf '\nImportant:\n'
printf '  %s\n' \
  "Restart or recreate the nginx container after replacing these files." \
  "If NGINX_CERT_HOSTNAME and NGINX_CERT_ALT_NAMES are unset, the existing server certificate CN/SANs are preserved automatically."
printf '\nEnvironment overrides:\n'
printf '  %s\n' "NGINX_CERT_HOSTNAME" "NGINX_CERT_ALT_NAMES" "NGINX_CERT_DAYS"
