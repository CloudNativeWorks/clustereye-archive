#!/usr/bin/env bash
# tls.sh — TLS certificate provisioning (self-signed or user-provided)

readonly TLS_DIR="/etc/clustereye/tls"
readonly TLS_CERT="${TLS_DIR}/server.crt"
readonly TLS_KEY="${TLS_DIR}/server.key"

tls::setup() {
  log::step "Configuring TLS certificates"

  case "${CE_TLS:-self-signed}" in
    self-signed) tls::_generate_self_signed ;;
    provided)    tls::_install_provided ;;
    *) die "Invalid --tls value: $CE_TLS (expected: self-signed|provided)" ;;
  esac
}

tls::_generate_self_signed() {
  if [[ -f "$TLS_CERT" && -f "$TLS_KEY" ]]; then
    log::info "Existing TLS certificates found — preserving"
    return 0
  fi

  log::info "Generating 10-year self-signed ECDSA certificate..."

  # Build SANs list
  local sans="DNS:localhost,IP:127.0.0.1,IP:::1"

  # Add --domain to SANs
  if [[ -n "${CE_DOMAIN:-}" ]]; then
    if [[ "$CE_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      sans="${sans},IP:${CE_DOMAIN}"
    else
      sans="${sans},DNS:${CE_DOMAIN}"
    fi
  fi

  # Add --bind-host to SANs
  local bind_host="${CE_BIND_HOST:-0.0.0.0}"
  if [[ "$bind_host" != "0.0.0.0" && "$bind_host" != "::" && "$bind_host" != "${CE_DOMAIN:-}" ]]; then
    if [[ "$bind_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      sans="${sans},IP:${bind_host}"
    else
      sans="${sans},DNS:${bind_host}"
    fi
  fi

  if [[ -n "${CE_EXTRA_HOSTNAMES:-}" ]]; then
    IFS=',' read -ra hostnames <<< "$CE_EXTRA_HOSTNAMES"
    for h in "${hostnames[@]}"; do
      h=$(echo "$h" | xargs)  # trim whitespace
      if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        sans="${sans},IP:${h}"
      else
        sans="${sans},DNS:${h}"
      fi
    done
  fi

  # Create OpenSSL config (multi-distro compatible, no -addext)
  local cnf
  cnf=$(mktemp)
  cat > "$cnf" <<EOF
[req]
default_bits       = 256
prompt             = no
distinguished_name = dn
x509_extensions    = v3_ext

[dn]
CN = ClusterEye

[v3_ext]
subjectAltName = ${sans}
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF

  # Generate ECDSA key + self-signed cert
  openssl ecparam -name prime256v1 -genkey -noout -out "${TLS_KEY}.tmp" 2>/dev/null
  openssl req -new -x509 -key "${TLS_KEY}.tmp" -out "${TLS_CERT}.tmp" \
    -days 3650 -config "$cnf" -extensions v3_ext 2>/dev/null

  # Atomic rename
  mv -f "${TLS_KEY}.tmp" "$TLS_KEY"
  mv -f "${TLS_CERT}.tmp" "$TLS_CERT"
  rm -f "$cnf"

  # Permissions
  chmod 0600 "$TLS_KEY"
  chmod 0644 "$TLS_CERT"
  chown root:root "$TLS_KEY" "$TLS_CERT"

  log::ok "Self-signed TLS certificate generated (valid 10 years)"
  log::info "  Cert: $TLS_CERT"
  log::info "  Key:  $TLS_KEY"
  log::info "  SANs: $sans"
}

tls::_install_provided() {
  local cert_src="${CE_TLS_CERT:-}"
  local key_src="${CE_TLS_KEY:-}"

  [[ -n "$cert_src" ]] || die "--cert is required when --tls=provided"
  [[ -n "$key_src" ]]  || die "--key is required when --tls=provided"
  [[ -f "$cert_src" ]] || die "Certificate file not found: $cert_src"
  [[ -f "$key_src" ]]  || die "Key file not found: $key_src"

  install -m 0644 -o root -g root "$cert_src" "$TLS_CERT"
  install -m 0600 -o root -g root "$key_src" "$TLS_KEY"

  log::ok "User-provided TLS certificates installed"
}
