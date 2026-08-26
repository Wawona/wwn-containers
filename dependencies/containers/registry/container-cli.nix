# Native `container` CLI — image mgmt everywhere; `run` on macOS via wwn-containerd.
{ pkgs, lib ? pkgs.lib, ... }:
let
  wwn-oci = pkgs.callPackage ../oci-core.nix { };
  wwn-containerd =
    if pkgs.stdenv.hostPlatform.isDarwin then pkgs.callPackage ../macos/wwn-containerd.nix { } else null;
in
pkgs.callPackage ../cli/container-cli.nix {
  inherit wwn-oci wwn-containerd;
}
