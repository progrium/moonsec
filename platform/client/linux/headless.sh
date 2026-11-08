#!/usr/bin/env bash
# Runs a command inside a headless desktop for the Linux client: Weston's headless
# backend with the GL renderer (Mesa llvmpipe without a GPU), a D-Bus session, PipeWire
# and WirePlumber with a null audio sink. CI uses it; so can you on a machine without a
# display (Ubuntu 24.04: weston pipewire wireplumber dbus-daemon libgl1-mesa-dri).
#
#   platform/client/linux/headless.sh zig build test-linux
#   platform/client/linux/headless.sh zig-out/bin/moonsec-linux run sim --client linux
set -euo pipefail

work=$(mktemp -d)
export XDG_RUNTIME_DIR="$work/run"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY=moonsec-headless
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

weston --backend=headless --renderer=gl --socket="$WAYLAND_DISPLAY" --idle-time=0 --width=1280 --height=720 >"$work/weston.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep 0.05; done
if [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    echo "headless.sh: weston did not start" >&2
    cat "$work/weston.log" >&2
    exit 1
fi
grep -E "EGL vendor|GL renderer|Output .* enabled" "$work/weston.log" >&2 || true

dbus-daemon --session --fork --print-address=3 --print-pid=4 3>"$work/dbus.addr" 4>"$work/dbus.pid"
DBUS_SESSION_BUS_ADDRESS=$(head -1 "$work/dbus.addr")
export DBUS_SESSION_BUS_ADDRESS
pids+=("$(head -1 "$work/dbus.pid")")

pipewire >"$work/pipewire.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.05; done
wireplumber >"$work/wireplumber.log" 2>&1 &
pids+=($!)
sleep 1
# A sink for the client's stream to link to; the graph's dummy driver clocks it.
pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=moonsec-null media.class=Audio/Sink object.linger=true audio.position=[FL FR] }' >/dev/null
for _ in $(seq 1 50); do pw-cli ls Node 2>/dev/null | grep -q moonsec-null && break; sleep 0.1; done
pw-cli ls Node 2>/dev/null | grep -q moonsec-null || { echo "headless.sh: no PipeWire null sink" >&2; cat "$work/pipewire.log" "$work/wireplumber.log" >&2; exit 1; }
echo "headless.sh: Wayland $WAYLAND_DISPLAY, PipeWire with a null sink" >&2

set +e
"$@"
rc=$?
set -e
if [ $rc -ne 0 ]; then
    echo "--- weston.log (tail)" >&2
    tail -20 "$work/weston.log" >&2
    echo "--- wireplumber.log (tail)" >&2
    tail -20 "$work/wireplumber.log" >&2
fi
exit $rc
