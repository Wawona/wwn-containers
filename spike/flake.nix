{
  description = "Wawona Phase A spike — KDE Plasma in containers: guest waypipe --vsock server + host waypipe --socket-fds client over Containerization dialVsock. SPIKE ONLY (not product code).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # The container VM is arm64-only; nixpkgs-unstable has also dropped
      # x86_64-darwin, so the spike declares aarch64-darwin only.
      darwinSystems = [ "aarch64-darwin" ];
      linuxSystems = [ "aarch64-linux" "x86_64-linux" ];
      allSystems = darwinSystems ++ linuxSystems;
      forAll = nixpkgs.lib.genAttrs allSystems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowUnsupportedSystem = true;
        };
      };
    in
    {
      packages = forAll (system:
        let
          pkgs = pkgsFor system;
          isLinux = builtins.elem system linuxSystems;
        in
        if isLinux then {
          # Guest OCI image (dockerTools): waypipe + weston-flower + nested KWin.
          # Load it on macOS with `container image load`.
          wawona-plasma-guest-spike = pkgs.callPackage ./guest/plasma-spike-image.nix { };
        } else {
          # Host waypipe with a WORKING --socket-fds (SplitFD) transport.
          # Phase B productized this into
          # dependencies/containers/macos/waypipe-splitfd.nix (see main flake's
          # .#waypipe-splitfd); the spike references the same file.
          waypipe-splitfd = pkgs.callPackage ../dependencies/containers/macos/waypipe-splitfd.nix { };
          # Swift spike harness (runtime-compile staging, like wwn-containerd).
          wwn-containerd-spike = pkgs.callPackage ./host/spike-bridge.nix { };
        });

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
