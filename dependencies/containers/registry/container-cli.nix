# Native `container` CLI — image mgmt everywhere; `run` on macOS via wwn-containerd.
{ pkgs, lib ? pkgs.lib, ... }:
let
  wwn-oci = pkgs.callPackage ../oci-core.nix { };
  wwn-containerd =
    if pkgs.stdenv.isDarwin then pkgs.callPackage ../macos/containerd-bridge.nix { } else null;
in
pkgs.callPackage ../cli/container-cli.nix {
  inherit wwn-oci wwn-containerd;
}
