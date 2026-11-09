#!/usr/bin/env bash
# Runs a command inside a headless desktop for the Linux host tests: Weston with its
# PipeWire backend (the output is a PipeWire video node, pixman renderer, no GPU) and the
# kiosk shell (windows go fullscreen), a D-Bus session in which xdg-desktop-portal starts
# on first use, and PipeWire with WirePlumber and a null audio sink as the default sink.
# Ubuntu 24.04: weston pipewire pipewire-bin wireplumber dbus-daemon xdg-desktop-portal
#
#   platform/host/linux/headless.sh zig build test-linux-host
#
# The portal's ScreenCast backend is the test's own (platform/host/linux/testportal):
# the real portal frontend routes to it (moonsec-test.portal below), and it hands out the
# Weston output's node, so the host's portal client, the frontend's restore tokens and
# the PipeWire stream are the real ones. xdg-desktop-portal-wlr would be the obvious
# backend, but 0.7 refuses to cast without dma-buf, and there is no GPU here.
#
# The command sees WAYLAND_DISPLAY, DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR, plus
# MOONSEC_HEADLESS_NODE (the output's PipeWire node id), MOONSEC_HEADLESS_SIZE (WxH)
# and MOONSEC_TEST_PORTAL=1 (the test runs the ScreenCast backend).
set -euo pipefail

width=${MOONSEC_HEADLESS_WIDTH:-1280}
height=${MOONSEC_HEADLESS_HEIGHT:-720}
work=$(mktemp -d)
export XDG_RUNTIME_DIR="$work/run"
mkdir -m 700 "$XDG_RUNTIME_DIR"
# Portal state (the permission store keeps restore tokens' grants here).
export XDG_DATA_HOME="$work/data" XDG_CONFIG_HOME="$work/config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME/xdg-desktop-portal" "$work/portals"
export XDG_CURRENT_DESKTOP=moonsec-test XDG_SESSION_TYPE=wayland
export WAYLAND_DISPLAY=moonsec-host-headless
pids=()
cleanup() {
    for ((i = ${#pids[@]} - 1; i >= 0; i--)); do kill "${pids[$i]}" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# The test's ScreenCast backend, and the frontend told to use it. D-Bus starts the
# frontend (and the permission store) on first use with this environment.
cat >"$work/portals/moonsec-test.portal" <<CONF
[portal]
DBusName=org.freedesktop.impl.portal.desktop.moonsectest
Interfaces=org.freedesktop.impl.portal.ScreenCast;
UseIn=moonsec-test
CONF
cat >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" <<CONF
[preferred]
default=moonsec-test
CONF
export XDG_DESKTOP_PORTAL_DIR="$work/portals" MOONSEC_TEST_PORTAL=1

dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$work/dbus.addr" 4>"$work/dbus.pid"
DBUS_SESSION_BUS_ADDRESS=$(head -1 "$work/dbus.addr")
export DBUS_SESSION_BUS_ADDRESS
pids+=("$(head -1 "$work/dbus.pid")")

pipewire >"$work/pipewire.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.05; done
wireplumber >"$work/wireplumber.log" 2>&1 &
pids+=($!)

weston --backend=pipewire --renderer=pixman --shell=kiosk --socket="$WAYLAND_DISPLAY" --idle-time=0 \
    --width="$width" --height="$height" >"$work/weston.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 200); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep 0.05; done
if [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    echo "headless.sh: weston did not start" >&2
    cat "$work/weston.log" >&2
    exit 1
fi
node=""
for _ in $(seq 1 100); do
    node=$(pw-cli ls Node 2>/dev/null | awk '/^\tid / {id=$2} /node.name = "weston.pipewire"/ {print id}' | tr -d ',' | head -1)
    [ -n "$node" ] && break
    sleep 0.05
done
if [ -z "$node" ]; then
    echo "headless.sh: no PipeWire node for Weston's output" >&2
    cat "$work/weston.log" "$work/pipewire.log" >&2
    exit 1
fi
export MOONSEC_HEADLESS_NODE="$node" MOONSEC_HEADLESS_SIZE="${width}x${height}"

# A sink for the audio test to play into and capture back from its monitor.
pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=moonsec-null media.class=Audio/Sink object.linger=true audio.position=[FL FR] }' >/dev/null
sink=""
for _ in $(seq 1 50); do
    sink=$(pw-cli ls Node 2>/dev/null | awk '/^\tid / {id=$2} /node.name = "moonsec-null"/ {print id}' | tr -d ',' | head -1)
    [ -n "$sink" ] && wpctl set-default "$sink" 2>/dev/null && break
    sleep 0.1
done
if [ -z "$sink" ]; then
    echo "headless.sh: no PipeWire null sink" >&2
    cat "$work/pipewire.log" "$work/wireplumber.log" >&2
    exit 1
fi
echo "headless.sh: Weston $WAYLAND_DISPLAY (${width}x${height}) on PipeWire node $node, null sink $sink (default), portal on demand" >&2

set +e
"$@"
rc=$?
set -e
if [ $rc -ne 0 ] || [ -n "${MOONSEC_HEADLESS_LOGS:-}" ]; then
    for f in weston pipewire wireplumber; do
        echo "--- $f.log (tail)" >&2
        tail -"${MOONSEC_HEADLESS_LOG_LINES:-20}" "$work/$f.log" >&2
    done
fi
exit $rc
