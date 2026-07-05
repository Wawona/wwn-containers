# NixOS guest module: run an OCI rootfs inside a wwn-vms guest with crun/podman,
# surfacing the container's Wayland session to the host (Wawona) over
# vsock + waypipe. This is the wwn-containers execution backend for every target
# that has no native container runtime but can run a VM (iOS/iPadOS/visionOS/
# tvOS via QEMU-TCTI, Android via QEMU/AVF).
#
# Topology:
#   host (Wawona)  <-- vsock+waypipe --  guest cage compositor  <-- wayland --  OCI container app
#
# The OCI bundle (rootfs + config.json, produced by the Rust `wwn-oci` core on
# the host) is shared into the guest read-only over virtiofs (tag `oci-bundle`).
# The guest runs it with crun against a shared XDG_RUNTIME_DIR so the container's
# Wayland client reaches the guest compositor, whose framebuffer waypipe streams
# to the host.
{ config, pkgs, lib, ... }:

let
  # vsock port the guest waypipe server binds (matches wwn-vms guest topology).
  vsockPort = 1024;
  bundleMount = "/run/wawona/oci-bundle";
in
{
  # Rootless OCI execution stack in-guest.
  virtualisation.podman = {
    enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  environment.systemPackages = with pkgs; [ crun podman waypipe cage foot ];

  # Mount the host-provided OCI bundle over virtiofs (populated by wwn-oci on the
  # host). The wwn-vms engine attaches the virtiofs share with tag `oci-bundle`.
  fileSystems.${bundleMount} = {
    device = "oci-bundle";
    fsType = "virtiofs";
    options = [ "ro" "nofail" ];
  };

  # 1) Headless compositor whose output is streamed to the host by waypipe.
  systemd.services.wawona-container-compositor = {
    description = "Wawona in-guest Wayland compositor (waypipe -> host over vsock)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "wawona";
      Restart = "always";
      RestartSec = "2s";
    };
    environment = {
      XDG_RUNTIME_DIR = "/run/user/1000";
      WLR_BACKENDS = "headless";
      WLR_RENDERER = "pixman";
      WLR_NO_HARDWARE_CURSORS = "1";
    };
    script = ''
      mkdir -p "$XDG_RUNTIME_DIR"
      exec ${pkgs.waypipe}/bin/waypipe \
        --socket vsock:2:${toString vsockPort} \
        server -- ${pkgs.cage}/bin/cage -- ${pkgs.foot}/bin/foot
    '';
  };

  # 2) Run the OCI container against the shared compositor socket. crun executes
  # the bundle; WAYLAND_DISPLAY/XDG_RUNTIME_DIR point the container's client at
  # the guest compositor above.
  systemd.services.wawona-container = {
    description = "Run the OCI container bundle (crun) inside the guest";
    wantedBy = [ "multi-user.target" ];
    after = [ "wawona-container-compositor.service" ];
    requires = [ "wawona-container-compositor.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "3s";
    };
    environment = {
      XDG_RUNTIME_DIR = "/run/user/1000";
      WAYLAND_DISPLAY = "wayland-0";
    };
    script = ''
      set -euo pipefail
      if [ ! -f "${bundleMount}/config.json" ]; then
        echo "wawona-container: no OCI bundle at ${bundleMount} (share it from the host)" >&2
        exit 1
      fi
      # Stage a writable bundle (rootfs shared ro); crun needs a writable dir.
      work=/run/wawona/oci-run
      mkdir -p "$work"
      ${pkgs.util-linux}/bin/mount --bind "${bundleMount}" "$work" 2>/dev/null || cp -a "${bundleMount}/." "$work/"
      exec ${pkgs.crun}/bin/crun run --bundle "$work" wawona-oci
    '';
  };
}
