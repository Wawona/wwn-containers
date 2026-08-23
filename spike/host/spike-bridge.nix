# wwn-containerd-spike — runtime-compile staging wrapper (same model as
# wwn-containerd's containerd-bridge.nix): the Nix build only stages the
# SwiftPM package into the store; the actual `swift build` (which fetches
# apple/containerization) + ad-hoc codesign with
# com.apple.security.virtualization happen on first run via the host Swift
# toolchain, cached under $XDG_CACHE_HOME keyed by the store hash.
{ pkgs, lib, wawonaVersion ? "dev", ... }:

let
  pkgSrc = ./WWNContainerSpike;
  entitlements = ./WWNContainerSpike/wwn-containerd-spike.entitlements;
in
pkgs.writeShellApplication {
  name = "wwn-containerd-spike-run";
  runtimeInputs = [ pkgs.coreutils pkgs.rsync ];
  text = ''
    set -euo pipefail

    SWIFT=/usr/bin/swift
    CODESIGN=/usr/bin/codesign
    if [ ! -x "$SWIFT" ]; then
      echo "wwn-containerd-spike: /usr/bin/swift not found — Xcode command line tools required." >&2
      exit 1
    fi

    SRC="${pkgSrc}"
    SRC_KEY="$(basename "$SRC")"
    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/wwn-containerd-spike"
    BUILD_DIR="$CACHE_DIR/${wawonaVersion}-$SRC_KEY"
    BIN="$BUILD_DIR/wwn-containerd-spike"

    if [ ! -x "$BIN" ]; then
      echo "[wwn-containerd-spike] compiling spike harness (one-time, fetches apple/containerization) → $BIN" >&2
      mkdir -p "$BUILD_DIR/src"
      # Store sources are read-only; stage a writable copy for SwiftPM.
      rsync -a --delete --chmod=u+w "$SRC/" "$BUILD_DIR/src/"
      ( cd "$BUILD_DIR/src" && "$SWIFT" build -c release )
      cp "$BUILD_DIR/src/.build/release/wwn-containerd-spike" "$BIN.tmp"
      "$CODESIGN" --force --sign - --entitlements "${entitlements}" "$BIN.tmp"
      mv -f "$BIN.tmp" "$BIN"
    fi

    exec "$BIN" "$@"
  '';
  meta = with lib; {
    description = "Phase A spike: container + guest waypipe vsock + host waypipe --socket-fds relay";
    platforms = platforms.darwin;
  };
}
