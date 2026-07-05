{
  description = "wwn-containers: Wawona's OCI container substrate. Universal, fully-compliant OCI image management (pull/store/unpack) everywhere - even iOS/watchOS - plus execution backends where a Linux kernel is available: Apple containerization.framework on macOS, container-in-VM (wwn-vms) on mobile, QEMU/proot on Android. SKELETON - real backends are downstream (see README.md, COMPLIANCE.md).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.url = "github:Wawona/wwn-toolchain";
    wwn-toolchain.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.inputs.rust-overlay.follows = "rust-overlay";
    # Containers on every non-macOS target need a Linux kernel, which only a VM
    # provides -> wwn-containers depends on wwn-vms (github:Wawona/wwn-vms).
    # Wawona overrides this via `follows` so its own wwn-vms input is the single
    # source of truth for integrated builds.
    wwn-vms.url = "github:Wawona/wwn-vms";
    wwn-vms.inputs.nixpkgs.follows = "nixpkgs";
    wwn-vms.inputs.rust-overlay.follows = "rust-overlay";
    wwn-vms.inputs.wwn-toolchain.follows = "wwn-toolchain";
  };

  outputs = { self, nixpkgs, rust-overlay, wwn-toolchain, wwn-vms, ... }:
    let
      darwinSystems = [ "x86_64-darwin" "aarch64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      allSystems = darwinSystems ++ linuxSystems;
      forAll = nixpkgs.lib.genAttrs allSystems;
      inherit (wwn-toolchain.lib) withPlatformVariants;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
        config = { allowUnfree = true; allowUnsupportedSystem = true; android_sdk.accept_license = true; };
      };

      dir = ./dependencies/containers;
    in
    {
      # Registry fragment merged into Wawona's machine registry.
      #
      #   oci-image    universal OCI image management (pull/store/unpack). Pure
      #                userspace, no exec -> available on EVERY target incl. iOS/watchOS.
      #   oci-runtime  the per-target execution backend (containerization.framework
      #                on macOS, container-in-VM on mobile, QEMU/proot on Android).
      # The universal OCI core (wwn-oci) as a first-class package per system, so
      # Wawona and CI can build + unit-test it directly (phase 3). Cross-compiled
      # target variants land via wwn-toolchain later.
      packages = forAll (system:
        let pkgs = pkgsFor system; in {
          wwn-oci = pkgs.callPackage ./dependencies/containers/oci-core.nix { };
          default = pkgs.callPackage ./dependencies/containers/oci-core.nix { };
          # Native `container` CLI (SCAFFOLD): the command Wawona's native
          # terminals + wwn-zsh expose to manage/run containers on every target.
          # Command surface only for now; subcommands stubbed. Design:
          # Wawona/docs/2026-container-cli.md.
          container-cli = pkgs.callPackage ./dependencies/containers/cli/container-cli.nix { };
        } // (pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
          # macOS execution backend (Apple Containerization framework). Pure
          # staging; compiled on first run via host Swift (see containerd-bridge.nix).
          wwn-containerd = pkgs.callPackage ./dependencies/containers/macos/containerd-bridge.nix { };
        }));

      registryFragment = {
        oci-image = withPlatformVariants {
          macos = dir + "/stub.nix";
          ios = dir + "/stub.nix";
          ipados = dir + "/stub.nix";
          tvos = dir + "/stub.nix";
          visionos = dir + "/stub.nix";
          watchos = dir + "/stub.nix";
          android = dir + "/stub.nix";
          wearos = dir + "/stub.nix";
        };
        oci-runtime = withPlatformVariants {
          macos = dir + "/stub.nix";
          ios = dir + "/stub.nix";
          ipados = dir + "/stub.nix";
          tvos = dir + "/stub.nix";
          visionos = dir + "/stub.nix";
          watchos = dir + "/stub.nix";
          android = dir + "/stub.nix";
          wearos = dir + "/stub.nix";
        };
        # Native `container` CLI, cross-compiled per target (SCAFFOLD). The
        # macOS/dev scaffold is the `container-cli` flake package; per-target
        # builds land here later. See Wawona/docs/2026-container-cli.md.
        container-cli = withPlatformVariants {
          macos = dir + "/stub.nix";
          ios = dir + "/stub.nix";
          ipados = dir + "/stub.nix";
          tvos = dir + "/stub.nix";
          visionos = dir + "/stub.nix";
          watchos = dir + "/stub.nix";
          android = dir + "/stub.nix";
          wearos = dir + "/stub.nix";
        };
      };

      # Container-in-VM guest: the wwn-vms mobile NixOS guest extended with an
      # in-guest OCI runtime (crun/podman) that runs a host-provided OCI bundle
      # and streams its Wayland session to Wawona over vsock+waypipe. This is the
      # execution backend for every non-macOS target (iOS/iPadOS/visionOS/tvOS/
      # Android). Evaluable; artifacts build on the aarch64-linux builder.
      nixosConfigurations.wawona-container-guest =
        import "${wwn-vms}/dependencies/vms/mobile/guest.nix" {
          inherit nixpkgs;
          extraModule = ./dependencies/containers/container-in-vm/guest-module.nix;
        };

      # Per-target container capability matrix (with eval-time invariant
      # asserts, incl. the cross-dep "exec needs a kernel" check against
      # wwn-vms). `nix eval .#lib.capabilities` is the container capability lane.
      lib.capabilities = import ./capabilities.nix {
        vmsCapabilities = wwn-vms.lib.capabilities;
      };

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
