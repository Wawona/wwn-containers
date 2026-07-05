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
    # provides -> wwn-containers depends on wwn-vms. Local absolute path input
    # while both repos are pre-release (switched to github:Wawona/wwn-vms once
    # stable - see push-repos). Wawona overrides this via `follows` so its own
    # wwn-vms input is the single source of truth for integrated builds.
    wwn-vms.url = "path:/Users/8amps/Wawona/wwn-vms";
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
      };

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
