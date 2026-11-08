#!/bin/sh
# Lab TLS for a self-hosted relay without a public domain: a throwaway CA plus a relay cert
# signed by it. Clients trust the CA through the shim's relay_ca_pem option
# (`shim-echo --relay-ca DIR/ca.crt`, iroh.BindOptions.relay_ca_pem).
#
#   relay/lab-cert.sh DIR [SAN ...]     SANs like IP:10.91.3.1 or DNS:relay.lan
#
# Writes DIR/ca.crt, DIR/default.crt and DIR/default.key, the file names iroh-relay reads
# from its working directory with `cert_mode = "Manual"` (relay/lab.toml). The default SANs
# cover the netns tests (10.91.3.1), loopback and relay.moonsec.test. Needs openssl.
set -eu
dir=${1:?usage: lab-cert.sh DIR [SAN ...]}
shift
sans=${*:-IP:10.91.3.1 IP:127.0.0.1 DNS:localhost DNS:relay.moonsec.test}
san=$(printf '%s\n' $sans | paste -sd, -)

mkdir -p "$dir"
cd "$dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=moonsec relay lab CA" -keyout "$tmp/ca.key" -out ca.crt \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=moonsec relay lab" -keyout default.key -out "$tmp/relay.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san" > "$tmp/ext"
openssl x509 -req -in "$tmp/relay.csr" -CA ca.crt -CAkey "$tmp/ca.key" -CAserial "$tmp/ca.srl" -CAcreateserial \
  -days 30 -extfile "$tmp/ext" -out default.crt 2>/dev/null
# iroh-relay may run as another user (systemd unit, container); this key is lab-only.
chmod 0644 default.key
echo "lab cert in $dir: $san"
