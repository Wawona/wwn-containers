# Universal OCI image management (pull/store/unpack). Pure userspace — every target.
{ pkgs, ... }:
pkgs.callPackage ../oci-core.nix { }
