{
  pkgs,
  lib ? pkgs.lib,
  wawonaVersion ? "dev",
  ...
}:

# Apple `container` CLI (https://github.com/apple/container) — macOS only.
#
# SwiftPM deps are pinned with a swiftpm2nix-style lock (workspace-state v7;
# stock nixpkgs swiftpm2nix stops at v6). The Nix build stays PURE: it stages
# apple/container 1.2.2 plus hashed checkouts. Host `/usr/bin/swift` compiles
# on first run (Containerization needs the macOS 26 SDK), same model as
# wwn-containerd / vz-launcher.
#
# Gate: assert Darwin here; registry maps every other platform to
# apple-container-forbidden.nix. Never add this key to wwn-toolchain
# baseRegistry (L0). Canonical: Wawona/docs/wwn-repo-dag.md.

assert
  pkgs.stdenv.hostPlatform.isDarwin
  || throw "apple-container is macOS-only (Virtualization.framework).";

let
  helpers = import ./swiftpm2nix-helpers.nix {
    inherit lib;
    inherit (pkgs) fetchgit;
  };
  generated = helpers.helpers ./swiftpm2nix;

  src = pkgs.fetchFromGitHub {
    owner = "apple";
    repo = "container";
    rev = "0190097d06df0b9065f4c2d2c7873c649d81d493"; # tag 1.2.2
    hash = "sha256-yLT5OzqKoD4xcoigD2xXsyvXmkw7H/rRyBpJyBkkOwE=";
  };

  staged = pkgs.stdenvNoCC.mkDerivation {
    pname = "apple-container-src";
    version = "1.2.2";
    inherit src;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R . "$out/"
      chmod -R u+w "$out"
      cd "$out"
      ${generated.configure}
      runHook postInstall
    '';
    meta = {
      description = "Staged apple/container sources + swiftpm2nix checkouts";
      platforms = lib.platforms.darwin;
    };
  };
in
pkgs.writeShellApplication {
  name = "container";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.rsync
  ];
  text = ''
    set -euo pipefail

    SWIFT=/usr/bin/swift
    if [ ! -x "$SWIFT" ]; then
      echo "apple-container: /usr/bin/swift not found — Xcode 26 + macOS 15+ (26 recommended) required." >&2
      exit 1
    fi

    SRC="${staged}"
    SRC_KEY="$(basename "$SRC")"
    CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/wwn-apple-container"
    BUILD_DIR="$CACHE_DIR/${wawonaVersion}-$SRC_KEY"
    BIN="$BUILD_DIR/container"

    if [ ! -x "$BIN" ]; then
      echo "[apple-container] compiling CLI (one-time, host Swift, deps already in the Nix store) → $BIN" >&2
      mkdir -p "$BUILD_DIR/src"
      rsync -a --delete --chmod=u+w "$SRC/" "$BUILD_DIR/src/"
      (
        cd "$BUILD_DIR/src"
        export HOME="''${TMPDIR:-/tmp}"
        export SWIFTPM_HIDE_BENCHMARK_CORRUPTION_HELP=1
        "$SWIFT" build \
          -c release \
          --product container \
          --disable-sandbox \
          --skip-update \
          -Xswiftc -no-warnings-as-errors
      )
      cp "$BUILD_DIR/src/.build/release/container" "$BIN.tmp"
      mv -f "$BIN.tmp" "$BIN"
    fi

    exec "$BIN" "$@"
  '';
  meta = with lib; {
    description = "Apple container CLI (OCI images as lightweight VMs on macOS)";
    homepage = "https://github.com/apple/container";
    license = licenses.asl20;
    platforms = platforms.darwin;
    mainProgram = "container";
  };
}
