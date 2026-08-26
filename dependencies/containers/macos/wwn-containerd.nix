{
  pkgs,
  lib ? pkgs.lib,
  wawonaVersion ? "dev",
  ...
}:

# Prebuilt wwn-containerd for macOS. Compiles at `nix build` time (host Xcode
# Swift + macOS SDK), is ad-hoc signed with virtualization entitlements, and
# ships as a normal store binary. No runtime swift build / ~/.cache compile.

assert
  pkgs.stdenv.hostPlatform.isDarwin
  || throw "wwn-containerd is macOS-only (Apple Containerization.framework).";

let
  helpers = import ./swiftpm2nix-helpers.nix {
    inherit lib;
    inherit (pkgs) fetchgit;
  };
  generated = helpers.helpers ./wwn-containerd-swiftpm2nix;
  entitlements = ./wwn-containerd.entitlements;

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let
        name = builtins.baseNameOf path;
        rel = lib.removePrefix ((toString ./.) + "/") (toString path);
      in
      name == "Package.swift"
      || name == "Package.resolved"
      || rel == "Sources"
      || lib.hasPrefix "Sources/" rel;
  };

  staged = pkgs.stdenvNoCC.mkDerivation {
    pname = "wwn-containerd-src";
    version = wawonaVersion;
    inherit src;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R Package.swift Package.resolved Sources "$out/"
      chmod -R u+w "$out"
      cd "$out"
      ${generated.configure}
      runHook postInstall
    '';
    meta = {
      description = "Staged wwn-containerd sources + swiftpm2nix checkouts";
      platforms = lib.platforms.darwin;
    };
  };
in
pkgs.stdenv.mkDerivation {
  pname = "wwn-containerd";
  version = wawonaVersion;
  src = staged;
  nativeBuildInputs = [
    pkgs.cctools
    pkgs.rsync
  ];
  dontConfigure = true;
  dontStrip = true;
  dontFixup = true;

  # Host Xcode Swift build (impure; binary is cached in the Nix store afterward).
  __noChroot = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR/swift-home"
    mkdir -p "$HOME"

    # Host Xcode toolchain. Unset Nix stdenv's DEVELOPER_DIR (often a store
    # apple-sdk stub without swift) before probing the real host install.
    unset DEVELOPER_DIR SDKROOT
    XCODE_SELECT="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
    if [ -n "$XCODE_SELECT" ] \
      && [ -x "$XCODE_SELECT/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]; then
      export DEVELOPER_DIR="$XCODE_SELECT"
    else
      for dev_dir in \
        /Applications/Xcode*.app/Contents/Developer \
        /Library/Developer/CommandLineTools; do
        if [ -x "$dev_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]; then
          export DEVELOPER_DIR="$dev_dir"
          break
        fi
      done
    fi
    if [ -z "''${DEVELOPER_DIR:-}" ] || [ ! -d "''$DEVELOPER_DIR" ]; then
      echo "wwn-containerd: Xcode DEVELOPER_DIR not found (install Xcode 26+)." >&2
      exit 1
    fi
    export PATH="''$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:''$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:$PATH"
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [ -z "''${SDKROOT:-}" ] || [ ! -d "''$SDKROOT" ]; then
      export SDKROOT="''$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    fi
    SWIFT="''$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    CODESIGN=/usr/bin/codesign
    if [ ! -x "$SWIFT" ]; then
      echo "wwn-containerd: swift not found under $DEVELOPER_DIR." >&2
      exit 1
    fi
    if [ ! -x "$CODESIGN" ]; then
      echo "wwn-containerd: /usr/bin/codesign not found." >&2
      exit 1
    fi

    rsync -a --chmod=u+w "$src/" .
    chmod -R u+w .build 2>/dev/null || true
    export SWIFT_PM_CACHE_DIR="$HOME/.swiftpm"
    export SWIFT_PM_PLUGINS_CACHE_DIR="$HOME/.swiftpm/plugins"
    mkdir -p "$SWIFT_PM_CACHE_DIR" "$SWIFT_PM_PLUGINS_CACHE_DIR"
    export SWIFTPM_HIDE_BENCHMARK_CORRUPTION_HELP=1
    "$SWIFT" build \
      -c release \
      --disable-sandbox \
      --skip-update \
      -Xswiftc -no-warnings-as-errors

    BIN="$(find .build -path '*/release/wwn-containerd' -type f ! -path '*.dSYM/*' | head -1)"
    if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
      echo "wwn-containerd: swift build did not produce an executable." >&2
      exit 1
    fi

    "$CODESIGN" --force --sign - \
      --entitlements "${entitlements}" \
      "$BIN"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    BIN="$(find . -path '*/release/wwn-containerd' -type f ! -path '*.dSYM/*' | head -1)"
    if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
      echo "wwn-containerd: release binary missing after build." >&2
      exit 1
    fi
    install -m755 "$BIN" "$out/bin/wwn-containerd"
    runHook postInstall
  '';

  preferLocalBuild = true;
  allowSubstitutes = false;

  meta = with lib; {
    description = "Wawona macOS OCI execution backend (Apple Containerization.framework)";
    platforms = platforms.darwin;
    mainProgram = "wwn-containerd";
  };
}
