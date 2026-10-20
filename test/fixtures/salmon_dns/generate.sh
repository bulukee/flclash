#!/usr/bin/env bash
set -euo pipefail

# Synthetic local test credentials only. Never install this CA in a trust store.
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/extensions.cnf" <<'CONFIG'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = test.example
[ca_ext]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[server_ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:test.example
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CONFIG
cat > "$TEMP_DIR/ca.cnf" <<'CONFIG'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Salmon DNS Test CA
[ca_ext]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CONFIG

openssl genrsa -out "$TEMP_DIR/ca-key.pem" 2048
openssl req -new -x509 -sha256 -days 3650 -set_serial 1 \
  -key "$TEMP_DIR/ca-key.pem" \
  -config "$TEMP_DIR/ca.cnf" -extensions ca_ext \
  -out "$TEMP_DIR/ca-cert.pem"
openssl req -new -sha256 -key "$FIXTURE_DIR/test-key.pem" \
  -config "$TEMP_DIR/extensions.cnf" -out "$TEMP_DIR/server.csr"
# macOS rejects long-lived TLS server certificates. Use a one-year leaf.
openssl x509 -req -sha256 -days 365 -set_serial 2 \
  -in "$TEMP_DIR/server.csr" \
  -CA "$TEMP_DIR/ca-cert.pem" -CAkey "$TEMP_DIR/ca-key.pem" \
  -extfile "$TEMP_DIR/extensions.cnf" -extensions server_ext \
  -out "$TEMP_DIR/test-cert.pem"
openssl verify -CAfile "$TEMP_DIR/ca-cert.pem" \
  -purpose sslserver -verify_hostname test.example "$TEMP_DIR/test-cert.pem"
cp "$TEMP_DIR/ca-cert.pem" "$FIXTURE_DIR/ca-cert.pem"
cp "$TEMP_DIR/test-cert.pem" "$FIXTURE_DIR/test-cert.pem"
