# Rootless proot / user-namespace container backend for Android (Termux model).
#
# The lighter of the two Android execution paths (the other is container-in-VM
# via wwn-vms QEMU). proot uses ptrace + a user-namespace-style chroot to run an
# unpacked OCI rootfs WITHOUT root and WITHOUT JIT - so it is Play-Store
# compliant and much cheaper than a full VM for non-isolation-critical workloads.
#
# Input: an OCI rootfs already unpacked by the Rust `wwn-oci` core (pure
# userspace pull/unpack), plus the image config's env/entrypoint/cwd.
#
# This builds a launcher script wrapping proot. On device, `proot` is the
# aarch64-android build cross-compiled through `wwn-toolchain`; pass it in as
# `proot`. When `proot` is null (e.g. evaluating on a macOS host) this throws
# rather than pretending to run.
{
  pkgs,
  lib ? pkgs.lib,
  proot ? null,
}:

if proot == null then
  throw ''
    wwn-containers Android proot backend needs a `proot` package (aarch64-android,
    cross-compiled via wwn-toolchain). It runs a wwn-oci-unpacked rootfs rootless
    + jitless. Wire the toolchain build then pass `proot` here.
  ''
else
  pkgs.writeShellApplication {
    name = "wwn-oci-proot-run";
    runtimeInputs = [ proot pkgs.coreutils ];
    text = ''
      set -euo pipefail
      # Usage: wwn-oci-proot-run <rootfs-dir> [-- cmd...]
      ROOTFS="''${1:?usage: wwn-oci-proot-run <rootfs> [-- cmd...]}"
      shift || true
      if [ "''${1:-}" = "--" ]; then shift; fi
      CMD=( "$@" )
      [ "''${#CMD[@]}" -eq 0 ] && CMD=( /bin/sh )

      ENVV=( "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "HOME=/root" )
      # Forward the Wayland session so a GUI app in the rootfs reaches Wawona
      # (via waypipe bound in the surrounding session).
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        ENVV+=( "WAYLAND_DISPLAY=''${WAYLAND_DISPLAY}" "XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/0}" )
      fi

      # Rootless chroot into the OCI rootfs: -0 fakes uid 0 inside, -r sets root,
      # -b binds device/proc nodes proot emulates. No real root, no JIT.
      exec proot \
        -r "$ROOTFS" \
        -0 \
        -w / \
        -b /dev -b /proc -b /sys \
        /usr/bin/env "''${ENVV[@]}" "''${CMD[@]}"
    '';
    meta.description = "Run a wwn-oci rootfs rootless via proot (Android/Termux model)";
  }
