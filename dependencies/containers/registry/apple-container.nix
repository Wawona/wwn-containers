# macOS-only Apple `container` CLI. Other platforms must not evaluate this.
{ pkgs, lib, ... }:
assert pkgs.stdenv.isDarwin;
pkgs.callPackage ../macos/apple-container.nix { }
