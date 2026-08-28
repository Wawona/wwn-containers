# Relocatable aarch64-linux waypipe tree for Apple Containerization inject.
#
# Copies the (patched) waypipe binary + DT_NEEDED libs from its nix closure
# into $out/{bin,lib}, then patchelfs them to /opt/wawona-waypipe/….
# One virtiofs share; no per-store-path mounts.
{
  pkgs,
  lib,
  waypipe,
  patchelf ? pkgs.patchelf,
}:

let
  # Runtime closure of the linux waypipe (interpreter + NEEDED libs).
  waypipeClosure = pkgs.closureInfo { rootPaths = [ waypipe ]; };
in
pkgs.runCommand "waypipe-guest-root-${waypipe.version or "0.11.0"}" {
  nativeBuildInputs = [ patchelf pkgs.file ];
  inherit waypipe waypipeClosure;
  meta = {
    description = "Relocatable aarch64-linux waypipe for Wawona container inject";
  };
} ''
  set -euo pipefail
  mkdir -p $out/bin $out/lib

  cp -L "$waypipe/bin/waypipe" $out/bin/waypipe
  chmod u+w $out/bin/waypipe

  interp=$(patchelf --print-interpreter $out/bin/waypipe)
  cp -L "$interp" $out/lib/ld-linux-aarch64.so.1
  chmod u+w $out/lib/ld-linux-aarch64.so.1

  copy_needed() {
    local soname="$1"
    local found=""
    local p
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -d "$p/lib" ] || continue
      if [ -e "$p/lib/$soname" ]; then
        if file -b "$p/lib/$soname" 2>/dev/null | grep -q ELF; then
          found="$p/lib/$soname"
          break
        fi
        if [ -L "$p/lib/$soname" ]; then
          local tgt
          tgt=$(readlink "$p/lib/$soname")
          case "$tgt" in
            /*) ;;
            *) tgt="$p/lib/$tgt" ;;
          esac
          if [ -e "$tgt" ] && file -b "$tgt" 2>/dev/null | grep -q ELF; then
            found="$tgt"
            break
          fi
        fi
      fi
      local cand
      cand=$(ls -1 "$p/lib/$soname".* 2>/dev/null | head -1 || true)
      if [ -n "''${cand:-}" ] && file -b "$cand" 2>/dev/null | grep -q ELF; then
        found="$cand"
        break
      fi
    done < "$waypipeClosure/store-paths"

    if [ -z "$found" ]; then
      echo "waypipe-guest-root: missing ELF for $soname" >&2
      exit 1
    fi
    echo "copy $soname <- $found"
    cp -L "$found" "$out/lib/$soname"
    chmod u+w "$out/lib/$soname"
  }

  for so in $(patchelf --print-needed $out/bin/waypipe); do
    [ "$so" = "ld-linux-aarch64.so.1" ] && continue
    copy_needed "$so"
  done

  for so in libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2; do
    if [ ! -e "$out/lib/$so" ]; then
      copy_needed "$so" || true
    fi
  done

  patchelf \
    --set-interpreter /opt/wawona-waypipe/lib/ld-linux-aarch64.so.1 \
    --set-rpath /opt/wawona-waypipe/lib \
    $out/bin/waypipe
  chmod +x $out/bin/waypipe

  for f in $out/lib/*; do
    file -b "$f" | grep -q ELF || {
      echo "not ELF: $f" >&2
      file "$f" >&2
      exit 1
    }
  done
''
