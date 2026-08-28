# aarch64-linux waypipe with oneshot --vsock server listen (host dialVsock).
# Bundled into waypipe-guest-root for Apple Containerization inject.
{
  pkgs,
  lib,
  waypipe ? pkgs.waypipe,
}:

waypipe.overrideAttrs (old: {
  pname = "waypipe-guest-vsock";
  patches = (old.patches or [ ]) ++ [
    ./waypipe-server-vsock-listen.patch
  ];
})
