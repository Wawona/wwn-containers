# Prebaked desktop guest OCI for Machines container recipes.
#
# Built on aarch64-linux (or cross from Darwin via pkgsCross). Contains the
# binaries CLI recipes invoke directly (no `nix shell` at Start):
#   weston-flower, sway, swaybg, Hyprland, foot, labwc, weston, kwin_wayland.
# Ghostty is omitted here: its man/share paths collide with other layers in
# dockerTools; use host `nix shell` or a later optional layer for Ghostty.
#
# Load on macOS after build (OCI layout or tar from dockerTools):
#   container import <result-or-tar>
# Or bundle under Wawona.app/Contents/Resources/oci/.
{ pkgs, lib }:

pkgs.dockerTools.buildLayeredImage {
  name = "wawona-container-desktop";
  tag = "latest";

  contents = [
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    pkgs.which
    pkgs.weston
    pkgs.sway-unwrapped
    pkgs.swaybg
    pkgs.hyprland
    pkgs.foot
    pkgs.labwc
    pkgs.dbus
    pkgs.kdePackages.kwin
    pkgs.kdePackages.qtwayland
  ];

  # Avoid writing /etc/profile (collides / permission denied under fakechroot).
  fakeRootCommands = ''
    mkdir -p ./run/user/0 ./tmp ./dev ./proc ./sys
    chmod 0700 ./run/user/0
    chmod 1777 ./tmp
  '';

  config = {
    Cmd = [ "${pkgs.weston}/bin/weston-flower" ];
    Env = [
      "PATH=/bin:/sbin:/usr/bin:/usr/sbin"
      "HOME=/root"
      "XDG_RUNTIME_DIR=/run/user/0"
      "WLR_BACKENDS=wayland"
      "WLR_RENDERER=pixman"
      "WLR_LIBINPUT_NO_DEVICES=1"
    ];
    WorkingDir = "/";
  };

  meta = with lib; {
    description =
      "Wawona prebaked desktop OCI: flower/sway/hyprland/foot without nix shell";
    platforms = platforms.linux;
  };
}
