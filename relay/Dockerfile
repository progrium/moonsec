# iroh-relay for moonsec. Build from the repo root or from relay/:
#   docker build -t moonsec-relay relay/
# Run (public relay, Let's Encrypt; edit iroh-relay.toml first or mount your own):
#   docker run -d --name moonsec-relay --restart unless-stopped \
#     -p 80:80 -p 443:443 -p 7842:7842/udp -v moonsec-relay:/var/lib/iroh-relay moonsec-relay
# See relay/README.md (lab use, compose file, systemd alternative).

ARG RUST_VERSION=1.97.0
FROM docker.io/library/rust:${RUST_VERSION}-slim-bookworm AS build
ARG IROH_RELAY_VERSION=1.4.1
RUN cargo install iroh-relay@${IROH_RELAY_VERSION} --features server --locked --root /out \
 && strip /out/bin/iroh-relay \
 && install -d -m 0700 /out/state

# glibc, libgcc, CA certificates and a nonroot user (65532), no shell or package manager.
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /out/bin/iroh-relay /usr/local/bin/iroh-relay
COPY --from=build --chown=65532:65532 /out/state /var/lib/iroh-relay
COPY iroh-relay.toml /etc/iroh-relay/iroh-relay.toml
# Unprivileged: Docker and Podman let a container's non-root user bind ports below 1024 in the
# container's own network namespace (net.ipv4.ip_unprivileged_port_start=0). With host
# networking, use unprivileged ports (as relay/lab.toml does) or run with --user 0.
USER nonroot
# Manual certs (default.crt, default.key) and the Let's Encrypt cache live here.
WORKDIR /var/lib/iroh-relay
VOLUME /var/lib/iroh-relay
EXPOSE 80/tcp 443/tcp 7842/udp
ENV RUST_LOG=info
ENTRYPOINT ["/usr/local/bin/iroh-relay"]
CMD ["--config-path", "/etc/iroh-relay/iroh-relay.toml"]
