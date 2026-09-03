# NixOS guest module: run an OCI rootfs inside a wwn-vms guest with crun,
# surfacing the container's Wayland client to Wawona over vsock + waypipe.
# This backend is allowed on iOS/iPadOS, Android, macOS, and Linux. VM and
# container machine kinds remain forbidden on tvOS, watchOS, and visionOS.
#
# Topology:
#   host Wawona compositor <- vsock + waypipe <- OCI Wayland client
#
# The OCI bundle (rootfs + config.json, produced by the Rust `wwn-oci` core on
# the host) is shared into the guest read-only over 9p (QEMU `-virtfs` mount_tag
# `oci-bundle`; Linux hosts may use virtiofs with the same tag).
{ config, pkgs, lib, ... }:

let
  # vsock port the guest waypipe server binds (matches wwn-vms guest topology).
  vsockPort = 1024;
  bundleMount = "/run/wawona/oci-bundle";
in
{
  # The base mobile guest starts Foot. A container guest replaces that service
  # with the OCI process, so only one waypipe endpoint owns the vsock port.
  systemd.services.wawona-session.enable = lib.mkForce false;
  environment.systemPackages = with pkgs; [ crun waypipe ];

  # Mount the host-provided OCI bundle. Prefer virtiofs (Linux hosts); fall
  # back to 9p (QEMU `-virtfs`, iOS/macOS TCTI/HVF) with the same mount_tag.
  # The OCI bundle (rootfs + config.json, produced by the Rust `wwn-oci` core on
  # the host) is shared into the guest read-only (tag `oci-bundle`).
  fileSystems.${bundleMount} = {
    device = "oci-bundle";
    fsType = "9p";
    options = [ "trans=virtio" "version=9p2000.L" "ro" "nofail" ];
  };

  # Stage a writable runtime bundle over the read-only shared rootfs, then make
  # the OCI process the command launched by waypipe. The container therefore
  # speaks Wayland directly to Wawona and does not gain a substitute compositor.
  systemd.services.wawona-container = {
    description = "Run the OCI Wayland client and forward it to Wawona";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig.RequiresMountsFor = bundleMount;
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "3s";
      RuntimeDirectory = "wawona-container";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    environment = {
      XDG_RUNTIME_DIR = "/run/user/1000";
    };
    script = ''
      set -euo pipefail
      if [ ! -f "${bundleMount}/config.json" ]; then
        echo "wawona-container: no OCI bundle at ${bundleMount} (share it from the host)" >&2
        exit 1
      fi
      work=/run/wawona-container/bundle
      upper=/run/wawona-container/upper
      overlay_work=/run/wawona-container/overlay-work
      mkdir -p "$work/rootfs" "$upper" "$overlay_work" "$XDG_RUNTIME_DIR"
      cp "${bundleMount}/config.json" "$work/config.json"
      if ! ${pkgs.util-linux}/bin/mount -t overlay overlay \
        -o "lowerdir=${bundleMount}/rootfs,upperdir=$upper,workdir=$overlay_work" \
        "$work/rootfs"; then
        echo "wawona-container: overlay mount failed" >&2
        exit 1
      fi
      echo "READY bundle=${bundleMount} transport=vsock port=${toString vsockPort}" >&2
      exec ${pkgs.waypipe}/bin/waypipe --vsock -s ${toString vsockPort} server -- \
        ${pkgs.crun}/bin/crun run --bundle "$work" wawona-oci
    '';
    postStop = ''
      ${pkgs.crun}/bin/crun delete --force wawona-oci >/dev/null 2>&1 || true
      echo "STOPPED" >&2
    '';
  };
}
