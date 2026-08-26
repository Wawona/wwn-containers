# Deprecated: use wwn-containerd.nix (prebuilt at nix build time).
{ pkgs, ... }:
pkgs.callPackage ./wwn-containerd.nix { }
