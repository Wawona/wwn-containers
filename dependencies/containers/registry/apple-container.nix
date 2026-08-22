# macOS-only Apple `container` CLI. Other platforms must not evaluate this.
{ pkgs, lib, ... }:
assert pkgs.stdenv.hostPlatform.isDarwin;
pkgs.callPackage ../macos/apple-container.nix { }
