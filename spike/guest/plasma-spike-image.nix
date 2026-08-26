# Wawona Phase A spike — guest OCI image (aarch64-linux).
#
# Minimal desktop guest for the container track:
#   - waypipe 0.11.0 (nixpkgs, --vsock support) — the guest side of the pipe
#   - weston (weston-flower)              — trivial client for the vsock test
#   - kdePackages.kwin + qtwayland        — nested compositor test
#   - dbus                                — session bus for KWin
#
# The image is NOT a full Plasma session (no plasmashell/krunner yet — that is
# Phase C). It answers the two Phase A unknowns:
#   1. waypipe --vsock -s <port> server (guest binds, host dialVsock's in)
#   2. kwin_wayland --platform wayland renders under a nested parent
#
# Built with dockerTools; the host loads it with `container image load`.
{ pkgs, lib }:

let
  sessionScript = pkgs.writeTextFile {
    name = "wawona-spike-session.sh";
    destination = "/session.sh";
    executable = true;
    text = builtins.readFile ./session.sh;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "wawona-plasma-guest-spike";
  tag = "latest";

  contents = [
    pkgs.bash
    pkgs.coreutils
    pkgs.waypipe # 0.11.0 C build with --vsock
    pkgs.weston # weston-flower
    pkgs.kdePackages.kwin # kwin_wayland --platform wayland
    pkgs.kdePackages.qtwayland # Qt Wayland client platform plugin
    pkgs.dbus # dbus-run-session
    sessionScript
  ];

  # The container runs as root (wwn-containerd sets XDG_RUNTIME_DIR=/run/user/0).
  fakeRootCommands = ''
    mkdir -p /run/user/0 /tmp /dev /proc /sys
    chmod 0700 /run/user/0
    chmod 1777 /tmp
  '';

  config = {
    Cmd = [ "/session.sh" "flower" ];
    Env = [
      "PATH=/bin:/sbin:/usr/bin:/usr/sbin"
      "HOME=/root"
    ];
    WorkingDir = "/";
  };

  meta = with lib; {
    description = "Phase A spike guest: waypipe + weston-flower + nested KWin (aarch64-linux OCI image)";
    platforms = platforms.linux;
  };
}
