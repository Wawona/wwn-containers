#!/bin/sh
# Wawona Phase A spike — guest session entrypoint.
#
# Runs INSIDE the container as the child of the guest waypipe server:
#
#   waypipe --no-gpu --vsock -s <port> server -- /session.sh <mode>
#
# waypipe exports its own fake Wayland socket to us via WAYLAND_DISPLAY and
# expects XDG_RUNTIME_DIR to exist; everything we launch connects to that
# socket, which waypipe forwards over vsock to the host (Wawona).
set -eu

mode="${1:-flower}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

echo "[session] mode=$mode pid=$$"
echo "[session] WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>} XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
ls -la "$XDG_RUNTIME_DIR" 2>/dev/null || true

case "$mode" in
  flower)
    # Trivial client: validates the waypipe --vsock direction + SHM fd-passing
    # through the whole pipe (guest server -> vsock -> host fd -> Wawona).
    echo "[session] launching weston-flower"
    exec weston-flower
    ;;
  kwin)
    # KWin's nested Wayland backend: Plasma's compositor runs as a regular
    # Wayland client of waypipe, so the whole desktop is ONE Wawona window.
    # Software rendering (Qt raster + wl_shm); GPU is a follow-up.
    echo "[session] launching kwin_wayland --platform wayland (dbus session bus)"
    exec dbus-run-session -- kwin_wayland --platform wayland
    ;;
  *)
    echo "[session] unknown mode '$mode' (expected flower|kwin)" >&2
    exit 1
    ;;
esac
