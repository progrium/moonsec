# Self-hosted relay

moonsec endpoints fall back to an iroh relay when they can't hole-punch, and use it for QUIC
address discovery (QAD), which is how each side learns its public address. The n0 public relays
carried about 8 Mbit/s in S5b. A relay of our own, near the users, gives relay mode more room
and keeps traffic off shared infrastructure. Browser clients will always go through a relay
(design doc, Web client).

This directory packages iroh-relay 1.4.1, the version the shim's iroh 1.4.1 speaks:

| File | What it is |
| --- | --- |
| [`iroh-relay.toml`](iroh-relay.toml) | Production config: Let's Encrypt, HTTPS on 443, QAD on 7842/udp, per-client rate limit, metrics on loopback |
| [`lab.toml`](lab.toml) | The same shape with a manual cert, unprivileged ports and IPv4 binds; the netns tests and CI use it |
| [`lab-cert.sh`](lab-cert.sh) | Makes a throwaway CA and a relay cert for `lab.toml` (or for a LAN relay with no domain) |
| [`Dockerfile`](Dockerfile), [`compose.yaml`](compose.yaml) | Container image (distroless, non-root, 13 MB compressed) and a compose file |
| [`iroh-relay.service`](iroh-relay.service), [`iroh-relay.sysusers`](iroh-relay.sysusers) | systemd unit (hardened, `systemd-analyze security` 1.5 "OK") and its service user |

## What a deployment needs

- A Linux host with a public IPv4 address (IPv6 too if you have it; see the bind comment in
  `iroh-relay.toml`). The relay is light. One relayed 1080p60 stream is capped well under the
  per-client limit of 50 Mbit/s, so plan uplink bandwidth for the number of relayed sessions.
- A DNS name pointing at the host, such as `relay.example.com`.
- Inbound ports: **80/tcp** (HTTP: captive-portal probe), **443/tcp** (HTTPS and the WebSocket
  relay; Let's Encrypt validates over TLS-ALPN on this port), **7842/udp** (QAD).

Then set `hostname` and `contact` under `[tls]` in `iroh-relay.toml`.

### Container

```sh
docker build -t moonsec-relay relay/
docker compose -f relay/compose.yaml up -d      # mounts relay/iroh-relay.toml, keeps certs in a volume
```

or without compose:

```sh
docker run -d --name moonsec-relay --restart unless-stopped \
  -p 80:80 -p 443:443 -p 7842:7842/udp \
  -v $PWD/relay/iroh-relay.toml:/etc/iroh-relay/iroh-relay.toml:ro \
  -v moonsec-relay:/var/lib/iroh-relay moonsec-relay
```

The image runs as the distroless `nonroot` user. Docker and Podman let that user bind ports
below 1024 inside the container's network namespace, so published ports work as is. With
`--network host` that no longer holds, so use unprivileged ports there (as `lab.toml` does).
Metrics listen on the container's own loopback; publish them with
`metrics_bind_addr = "0.0.0.0:9090"` and `-p 127.0.0.1:9090:9090` if you scrape them.

### systemd

```sh
cargo install iroh-relay@1.4.1 --features server --locked     # or copy the binary out of the image
sudo install -m 0755 ~/.cargo/bin/iroh-relay /usr/local/bin/
sudo install -m 0644 relay/iroh-relay.sysusers /usr/lib/sysusers.d/iroh-relay.conf && sudo systemd-sysusers
sudo install -D -m 0644 relay/iroh-relay.toml /etc/iroh-relay/iroh-relay.toml   # then edit it
sudo install -m 0644 relay/iroh-relay.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now iroh-relay
journalctl -u iroh-relay -f
```

The unit runs as `iroh-relay` with only `CAP_NET_BIND_SERVICE`, a read-only filesystem except
`/var/lib/iroh-relay` (the Let's Encrypt cache and any manual certs), and a system-call
filter.

### Check it

```sh
curl https://relay.example.com/ping                       # 200 from the relay
zig build && zig-out/bin/shim-echo selftest --relay-url https://relay.example.com
```

The selftest binds two endpoints that use only this relay. Each must register with it, which
checks the certificate, the hostname and the ports, and then they echo 100 datagrams. On one
machine the connection usually goes direct after that, so a real relayed path needs two
networks. The netns tests below cover it.

## Pointing moonsec at it

Endpoints take relay URLs through `BindOptions` (`transport/iroh.zig`):

- `.relay_mode = .custom_only, .relay_urls = "https://relay.example.com"` uses only this relay,
  with no n0 discovery (dial by ticket).
- `.relay_mode = .custom` uses this relay plus n0's DNS/pkarr discovery.
- For a relay whose certificate comes from a private CA, such as one made by `lab-cert.sh`
  for a LAN relay with no public domain, pass the CA's PEM text as `.relay_ca_pem`. It is added
  to the built-in web roots (`shim-echo --relay-ca FILE` does the same).

iroh tries QAD on port 7842 of every relay, so that port isn't part of the URL.

## Lab use and tests

```sh
relay/lab-cert.sh /tmp/moonsec-relay-lab                  # ca.crt, default.crt, default.key
(cd /tmp/moonsec-relay-lab && iroh-relay --config-path $PWD/relay/lab.toml)
```

The shim's netns tests (`transport/iroh_netns_test.zig`) run the relay this way by default and
dial `https://10.91.3.1:3443`, trusting the lab CA. They check that the relay path takes over
the target rate when the direct path dies, and that an endpoint without the CA can't register.
To run them through an already running relay, such as the container or the systemd unit:

```sh
docker run -d --name relay-lab --network host \
  -v $PWD/relay/lab.toml:/etc/iroh-relay/iroh-relay.toml:ro \
  -v /tmp/moonsec-relay-lab:/var/lib/iroh-relay:ro moonsec-relay
zig build netns-test
sudo MOONSEC_RELAY_URL=https://10.91.3.1:3443 MOONSEC_RELAY_CA=/tmp/moonsec-relay-lab/ca.crt zig-out/bin/iroh-netns-test
```

CI ([`.github/workflows/relay.yml`](../.github/workflows/relay.yml)) installs the unit under
the runner's systemd and runs the netns tests through it, does the same with the container,
and then starts the image's own Let's Encrypt config to check that it parses and binds
80/443/7842 as non-root. ACME points at a dead URL there, so CI never contacts Let's Encrypt.

## Not covered yet

- **Access control.** The config allows every endpoint, like n0's relays. iroh-relay can
  require a shared token (`access.shared_token`), but the shim doesn't send relay auth tokens
  yet, so that would lock moonsec out. An endpoint allowlist (`access.allowlist`) works for a
  private relay today. The per-client rate limit caps what any one endpoint can push.
- **A real deployment.** Nothing here has run on a public host with a real domain and Let's
  Encrypt. CI checks only that the Let's Encrypt config starts.
- **Relay throughput.** No measurement yet of what one relay carries for moonsec media. S5b
  measured only the n0 relay (~8 Mbit/s).
