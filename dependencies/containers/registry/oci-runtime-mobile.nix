# Mobile execution: container-in-VM (crun/podman in wwn-vms guest + virtiofs OCI bundle).
{ pkgs, lib ? pkgs.lib, ... }:
pkgs.writeTextDir "README" ''
  wwn-containers mobile runtime: container-in-VM via wwn-vms.

  Host app boots the mobile/container NixOS guest; OCI bundle is shared over virtiofs
  (tag oci-bundle). Guest runs crun + waypipe → Wawona compositor.

  Wawona: WWNContainerRunner delegates to WWNVirtualMachineRunner on iOS/iPadOS/tvOS/visionOS.
  Guest module: wwn-containers/dependencies/containers/container-in-vm/guest-module.nix
''
