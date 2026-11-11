#!/usr/bin/env bash
# Cloud test for the Linux packages (7G): installs the .deb in this machine or container
# (as root), checks the files, the unit and the udev rule, then pairs a client and starts
# the host through the installed launcher and has the client stream from it over iroh on
# this machine. Uses the synthetic backend, so no GPU, display or /dev/uinput is needed.
#
#   sudo packaging/linux/test-install.sh dist/moonsec_*_amd64.deb [dist/moonsec-*.rpm]
#
# The .rpm, when given, is checked for its file list and requirements (rpm -qp), since
# installing it needs an rpm-based system.
set -euo pipefail
deb="${1:?usage: test-install.sh PATH.deb [PATH.rpm]}"
rpmf="${2:-}"
fail=0
step() { printf '\n== %s\n' "$*"; }
check() { if "$@"; then echo "  ok: $*"; else echo "  FAIL: $*"; fail=1; fi; }

step "install $deb"
if command -v apt-get >/dev/null; then
  apt-get install -y -q "$(readlink -f "$deb")" >/dev/null
else
  dpkg -i "$deb"
fi
dpkg -s moonsec | sed -n 's/^\(Version\|Depends\|Architecture\): /  \1: /p'

step "files"
for f in /usr/bin/moonsec /usr/lib/moonsec/moonsec-host /usr/lib/systemd/user/moonsec-host.service \
         /usr/lib/udev/rules.d/60-moonsec-uinput.rules /usr/lib/modules-load.d/moonsec-uinput.conf; do
  check test -e "$f"
done
# Read the docs from the package itself: minimal images drop /usr/share/doc (dpkg path-exclude).
notices="$(dpkg-deb --fsys-tarfile "$deb" | tar -xO ./usr/share/doc/moonsec/THIRD_PARTY_NOTICES.md)"
check grep -q '^## libopus' <<<"$notices"
check grep -q 'iroh shim: Rust crates' <<<"$notices"
check sh -c "dpkg-deb -c '$deb' | grep -q ./usr/share/doc/moonsec/copyright"

step "unit and udev rule"
if command -v systemd-analyze >/dev/null; then
  # --user needs a user manager; verify the file itself (ExecStart exists, syntax).
  check systemd-analyze verify /usr/lib/systemd/user/moonsec-host.service
fi
if udevadm verify --help >/dev/null 2>&1; then
  check udevadm verify /usr/lib/udev/rules.d/60-moonsec-uinput.rules
fi

step "pair a client with the installed binary"
t="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$t"' EXIT
export HOME="$t/host-home" XDG_CONFIG_HOME="$t/host-home/.config" XDG_STATE_HOME="$t/host-home/.local/state"
mkdir -p "$HOME"
client="$t/client"
moonsec pair host --name pkg-test --ticket-file "$t/pair-ticket" --seconds 60 > "$t/pair-host.log" 2>&1 &
pair_host=$!
for _ in $(seq 1 200); do [ -s "$t/pair-ticket" ] && break; sleep 0.05; done
check moonsec pair client --state-dir "$client" --name pkg-client --ticket-file "$t/pair-ticket"
check wait $pair_host
check sh -c "moonsec paired | grep -q 'clients allowed to connect (1)'"

step "start the host from the package (launcher, as the unit runs it) and stream 5 s"
# MOONSEC_HOST_ARGS is how host.env adds options; --seconds keeps the run short.
MOONSEC_HOST_ARGS="--seconds 5" timeout 120 /usr/lib/moonsec/moonsec-host > "$t/host.log" 2>&1 &
host=$!
ticket="$XDG_STATE_HOME/moonsec/host-ticket"
for _ in $(seq 1 200); do [ -s "$ticket" ] && break; sleep 0.05; done
check test -s "$ticket"
if moonsec peer iroh client --state-dir "$client" --ticket-file "$ticket" --seconds 5 > "$t/client.log" 2>&1; then
  echo "  ok: paired client streamed from the packaged host"
else
  echo "  FAIL: client"; fail=1; kill $host 2>/dev/null || true
fi
check wait $host
sed 's/^/  host| /' "$t/host.log" | head -20
sed 's/^/  client| /' "$t/client.log" | head -20

if [ -n "$rpmf" ]; then
  step "rpm $rpmf"
  rpm -qpi "$rpmf" 2>/dev/null | sed -n 's/^\(Name\|Version\|License\|Architecture\) *: /  \1: /p'
  rpm -qpR "$rpmf" 2>/dev/null | sed 's/^/  requires: /'
  for f in /usr/bin/moonsec /usr/lib/systemd/user/moonsec-host.service /usr/lib/udev/rules.d/60-moonsec-uinput.rules; do
    check sh -c "rpm -qpl '$rpmf' 2>/dev/null | grep -qx '$f'"
  done
fi

step "remove"
check dpkg -r moonsec >/dev/null
check test ! -e /usr/bin/moonsec

echo
if [ $fail = 0 ]; then echo "linux packages: pass"; else echo "linux packages: FAIL"; fi
exit $fail
