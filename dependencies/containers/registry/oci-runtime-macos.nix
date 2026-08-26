# macOS execution: Apple Containerization.framework via wwn-containerd.
{ pkgs, lib, ... }:
assert pkgs.stdenv.hostPlatform.isDarwin;
pkgs.callPackage ../macos/wwn-containerd.nix { }
