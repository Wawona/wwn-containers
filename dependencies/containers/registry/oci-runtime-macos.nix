# macOS execution: Apple Containerization.framework via wwn-containerd.
{ pkgs, lib, ... }:
assert pkgs.stdenv.isDarwin;
pkgs.callPackage ../macos/containerd-bridge.nix { }
