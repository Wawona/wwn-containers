# Android execution: rootless proot when cross-built; otherwise registry anchor.
{ pkgs, lib ? pkgs.lib, proot ? null, ... }:
if proot != null then
  import ../android/proot-runner.nix {
    inherit pkgs lib proot;
  }
else
  pkgs.writeTextDir "README" ''
    wwn-containers Android runtime: proot (rootless) or container-in-VM (QEMU/AVF).

    Wire `proot` from wwn-toolchain aarch64-android, or use container-in-VM via wwn-vms.
    Wawona: AndroidMachineSessionBridge → AndroidVmRunner / AndroidContainerRunner.
  ''
