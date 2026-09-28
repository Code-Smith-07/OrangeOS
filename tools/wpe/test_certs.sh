#!/bin/sh
# A throwaway certificate authority and server certificate for the HTTPS
# fixture in tools/runtime_smoke.py (10.0.2.2 is the host as QEMU's user
# network shows it). Made once into build/wpe/test-certs; never a real CA.
set -eu
cd "$(dirname "$0")/../.."
OUT=build/wpe/test-certs
[ -f "$OUT/server.pem" ] && exit 0
mkdir -p "$OUT"
cat > "$OUT/server.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = 10.0.2.2
[server]
subjectAltName = IP:10.0.2.2
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
CNF
cat > "$OUT/ca.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = OrangeOS test CA
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$OUT/ca.cnf" -extensions ca -keyout "$OUT/ca.key" -out "$OUT/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -config "$OUT/server.cnf" -keyout "$OUT/server.key" -out "$OUT/server.csr" 2>/dev/null
openssl x509 -req -in "$OUT/server.csr" -CA "$OUT/ca.pem" -CAkey "$OUT/ca.key" -CAcreateserial -days 3650 \
    -extfile "$OUT/server.cnf" -extensions server -out "$OUT/server.pem" 2>/dev/null
echo "test certificates in $OUT"
