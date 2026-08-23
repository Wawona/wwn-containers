#!/usr/bin/env bash
# Wawona Phase A spike — boot test driver (macOS host).
#
# Validates the two Phase A unknowns:
#   1. waypipe --vsock direction: guest `waypipe --vsock -s <port> server`
#      (binds in-guest) <- dialed by the host via Containerization dialVsock,
#      handed to the host waypipe client as raw fds (--socket-fds).
#   2. kwin_wayland --platform wayland renders under a nested parent.
#
# Prereqs:
#   - Wawona running (WAYLAND_DISPLAY socket reachable)
#   - Apple container system started (`container system start`)
#   - an aarch64-linux builder for the guest image (local VZ Linux builder or
#     remote); if absent, build it in CI and copy the tar.gz here.
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\n\033[1;36m[boot-test]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[boot-test] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

SPIKE="wwn-containerd-spike-run"
WP="${WWNP_WAYPIPE_BIN:-}"
VSOCK_PORT="${WWN_SPIKE_VSOCK_PORT:-1024}"
IMAGE_REF="${WWN_SPIKE_IMAGE:-wawona-plasma-guest-spike}"
MODE="${1:-flower}"

# ---- prereqs ---------------------------------------------------------------
log "checking prereqs"
command -v nix >/dev/null || fail "nix not found"
command -v container >/dev/null || fail "container CLI not found"

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  WAYLAND_DISPLAY="${XDG_RUNTIME_DIR:-/tmp/wawona-501}/wayland-0"
  [ -S "$WAYLAND_DISPLAY" ] || fail "Wawona compositor socket not found at $WAYLAND_DISPLAY — start Wawona first"
  export WAYLAND_DISPLAY
fi
log "WAYLAND_DISPLAY=$WAYLAND_DISPLAY (Wawona compositor)"

container system start 2>/dev/null || log "container system: assuming already started"

# ---- 1. guest image --------------------------------------------------------
log "building guest image (aarch64-linux)…"
if ! nix build --no-link --print-out-paths ".#wawona-plasma-guest-spike" -o result-plasma-spike 2>/tmp/spike-image-build.log; then
  cat /tmp/spike-image-build.log >&2
  fail "guest image build failed — no aarch64-linux builder on this machine?
  Options: enable the Determinate VZ Linux builder, or build in CI and copy
  the result here. See spike/README.md."
fi
IMAGE_TAR="$(cd result-plasma-spike && pwd -P)"
log "guest image: $IMAGE_TAR"

log "loading image into the Apple container image store…"
container image load -i "$IMAGE_TAR" --force
container image list | grep -i plasma || true
log "NOTE: if the loaded reference differs from '$IMAGE_REF', pass the exact
     name via WWN_SPIKE_IMAGE (e.g. 'wawona-plasma-guest-spike:latest')."

# ---- 2. host waypipe (patched --socket-fds) --------------------------------
if [ -z "$WP" ]; then
  log "building host waypipe (SplitFD patch)…"
  nix build --no-link --print-out-paths ".#waypipe-splitfd" -o result-waypipe-splitfd
  WP="$(cd result-waypipe-splitfd && pwd -P)/bin/waypipe"
fi
"$WP" --help 2>&1 | grep -q -- "--socket-fds" \
  || fail "$WP lacks --socket-fds (unpatched build?)"
log "host waypipe: $WP"

# ---- 3. spike harness ------------------------------------------------------
log "building spike harness (staging; compiles on first run)…"
nix build --no-link --print-out-paths ".#wwn-containerd-spike" -o result-spike-run
SPIKE="$(cd result-spike-run && pwd -P)/bin/$SPIKE"

# ---- 4. run ----------------------------------------------------------------
log "boot test: mode=$mode (vsock port $VSOCK_PORT)"
log "expect a window in Wawona. Close it to end the test."
WWNP_WAYPIPE_BIN="$WP" "$SPIKE" \
  --image "$IMAGE_REF" \
  --mode "$MODE" \
  --vsock-port "$VSOCK_PORT" \
  --waypipe-bin "$WP"

log "boot test finished cleanly."

# ---- results checklist -----------------------------------------------------
cat <<'EOF'
Phase A results checklist
-------------------------
[ ] guest waypipe bound vsock port without error (see [session] logs above)
[ ] host dialVsock connected (see [spike] dialVsock line)
[ ] waypipe client stayed alive (no --socket-fds panic / fd errors)
[ ] a window appeared in Wawona
[ ] (flower) window shows weston-flower's three rotating rectangles
[ ] (kwin)  window shows a KWin desktop (black bg + cursor + kwin logo,
     taskbar-less; nested backend quirks expected)
[ ] closing the window ends the container cleanly (exit 0, no zombie)
EOF
