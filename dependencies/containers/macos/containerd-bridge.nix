{
  pkgs,
  wawonaVersion ? "dev",
  ...
}:

# wwn-containerd — macOS OCI execution backend built on Apple's Containerization
# framework. Like wwn-vms' vz-launcher, the Nix build stays PURE: it only stages
# the SwiftPM package (Package.swift + Sources) into the store. The actual
# `swift build` (which fetches apple/containerization + needs the macOS 15+ SDK)
# and ad-hoc codesign with `com.apple.security.virtualization` happen on first
# run using the host Swift toolchain, cached under $XDG_CACHE_HOME keyed by the
# store hash of the sources so upgrades recompile automatically.

let
  pkgSrc = ./.;
  entitlements = ./wwn-containerd.entitlements;
in
pkgs.writeShellApplication {
  name = "wwn-containerd-run";
  runtimeInputs = [ pkgs.coreutils pkgs.rsync ];
  text = ''
    set -euo pipefail

    # Host toolchain (not from Nix): Containerization needs the macOS SDK +
    # Swift 6 from the installed Xcode / command line tools.
    SWIFT=/usr/bin/swift
    CODESIGN=/usr/bin/codesign
    if [ ! -x "$SWIFT" ]; then
      echo "wwn-containerd: /usr/bin/swift not found — Xcode command line tools required." >&2
      exit 1
    fi

    SRC="${pkgSrc}"
    SRC_KEY="$(basename "$SRC")"
    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/wwn-containerd"
    BUILD_DIR="$CACHE_DIR/${wawonaVersion}-$SRC_KEY"
    BIN="$BUILD_DIR/wwn-containerd"

    if [ ! -x "$BIN" ]; then
      echo "[wwn-containerd] compiling backend (one-time, fetches apple/containerization) → $BIN" >&2
      mkdir -p "$BUILD_DIR/src"
      # Store sources are read-only; stage a writable copy for SwiftPM.
      rsync -a --delete --chmod=u+w "$SRC/" "$BUILD_DIR/src/"
      ( cd "$BUILD_DIR/src" && "$SWIFT" build -c release )
      cp "$BUILD_DIR/src/.build/release/wwn-containerd" "$BIN.tmp"
      "$CODESIGN" --force --sign - --entitlements "${entitlements}" "$BIN.tmp"
      mv -f "$BIN.tmp" "$BIN"
    fi

    exec "$BIN" "$@"
  '';
  meta = with pkgs.lib; {
    description = "Run Linux OCI containers on macOS via Apple's Containerization framework";
    platforms = platforms.darwin;
  };
}
