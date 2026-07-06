# Native `container` CLI - the command Wawona's native terminals + wwn-zsh
# expose so a user can manage and run OCI containers from a shell "like on a
# real computer".
#
# IMPLEMENTED (this file is no longer a scaffold):
#   * image management (pull/images/rmi/inspect/resolve) -> wwn-oci (Rust),
#     universal + App-Store-compliant on every target.
#   * run  -> per-target execution backend. macOS: wwn-containerd (Apple
#     Containerization framework, per-container VM). Other targets: honest
#     error until their backends land (container-in-VM via wwn-vms / proot).
#
# NOT YET IMPLEMENTED (exit 3 with an honest message):
#   * exec/ps/start/stop/rm/logs - need a persistent containerd session
#     (wwn-containerd is currently one-shot run+wait). Tracked in
#     Wawona/docs/2026-container-cli.md.
{
  pkgs,
  wwn-oci,
  # macOS execution backend (wwn-containerd-run wrapper). Null on non-darwin.
  wwn-containerd ? null,
}:
pkgs.writeShellApplication {
  name = "container";
  runtimeInputs = [ wwn-oci ] ++ pkgs.lib.optional (wwn-containerd != null) wwn-containerd;
  text = ''
    # Backend selection: WAWONA_CONTAINER_BACKEND is set by the host app
    # (WWNContainerRunner sets "containerization" on macOS); default = auto.
    BACKEND="''${WAWONA_CONTAINER_BACKEND:-auto}"

    usage() {
      cat <<'EOF'
    container - Wawona native OCI container CLI

    USAGE:
      container <command> [args]

    IMAGE MANAGEMENT (universal - every Wawona target, incl. iOS/watchOS):
      pull <ref>            download an OCI image (digest-verified) + unpack rootfs
      images                list pulled images
      rmi <ref>             remove an image (keeps shared blobs)
      inspect <ref>         show image manifest/config/layers/rootfs
      resolve <ref>         print the parsed reference components

    LIFECYCLE (only where a Linux kernel is available):
      run <ref> [cmd...]    boot a per-container VM and run a process (macOS:
                            Apple Containerization framework via wwn-containerd)
      exec|ps|start|stop|rm|logs   NOT IMPLEMENTED YET (needs persistent session)

    ENVIRONMENT:
      WWN_OCI_ROOT          image store root (default ~/.local/share/wwn-oci)
      WAWONA_VM_KERNEL      Linux kernel for `run` (default: newest kernel under
                            ~/Library/Application Support/com.apple.container/kernels)
      WAWONA_VM_INITFS      prebuilt vminitd ext4 initfs for `run` (optional;
                            falls back to vminit:latest in the local image store)
      WAWONA_CONTAINER_BACKEND  backend override (macOS: containerization)
    EOF
    }

    if [ "$#" -eq 0 ]; then
      usage
      exit 2
    fi

    cmd="$1"
    shift || true

    find_kernel() {
      if [ -n "''${WAWONA_VM_KERNEL:-}" ]; then
        printf '%s\n' "$WAWONA_VM_KERNEL"
        return 0
      fi
      # Newest kernel provisioned by Apple's container tool / Wawona setup.
      local kdir="$HOME/Library/Application Support/com.apple.container/kernels"
      if [ -d "$kdir" ]; then
        local k
        k="$(find "$kdir" -type f -name 'vmlinux*' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)"
        if [ -n "$k" ]; then
          printf '%s\n' "$k"
          return 0
        fi
      fi
      return 1
    }

    case "$cmd" in
      -h|--help|help)
        usage
        exit 0
        ;;
      pull|images|rmi|inspect|resolve)
        exec wwn-oci "$cmd" "$@"
        ;;
      run)
        if [ "$#" -eq 0 ]; then
          echo "container: run needs an image reference" >&2
          exit 2
        fi
        REF="$1"
        shift || true
        # Containerization's reference parser needs a fully-qualified ref;
        # apply Docker's shorthand heuristic (alpine -> docker.io/library/alpine).
        case "$REF" in
          */*)
            first="''${REF%%/*}"
            case "$first" in
              localhost|*.*|*:*) ;;              # already has a registry host
              *) REF="docker.io/$REF" ;;
            esac
            ;;
          *) REF="docker.io/library/$REF" ;;
        esac
        case "$(uname -s):$BACKEND" in
          Darwin:auto|Darwin:containerization)
            if ! command -v wwn-containerd-run >/dev/null 2>&1; then
              echo "container: wwn-containerd backend not available in this build." >&2
              exit 3
            fi
            if ! KERNEL="$(find_kernel)"; then
              echo "container: no Linux kernel found for the VM." >&2
              echo "  set WAWONA_VM_KERNEL=/path/to/vmlinux (or install one via" >&2
              echo "  Apple's \`container system start --enable-kernel-install\`)." >&2
              exit 3
            fi
            INITFS_ARGS=()
            if [ -n "''${WAWONA_VM_INITFS:-}" ]; then
              INITFS_ARGS=(--initfs "$WAWONA_VM_INITFS")
            fi
            # Default command: the image's /bin/sh (wwn-containerd default).
            exec wwn-containerd-run run -i "$REF" -k "$KERNEL" "''${INITFS_ARGS[@]}" "$@"
            ;;
          *)
            echo "container: 'run' is not implemented on this platform/backend yet ($(uname -s), backend=$BACKEND)." >&2
            echo "container: execution lands via container-in-VM (wwn-vms). Image management works everywhere." >&2
            exit 3
            ;;
        esac
        ;;
      exec|ps|start|stop|rm|logs)
        echo "container: '$cmd' is not implemented yet (needs a persistent container session; wwn-containerd is one-shot run+wait for now)." >&2
        echo "container: tracked in Wawona/docs/2026-container-cli.md." >&2
        exit 3
        ;;
      *)
        echo "container: unknown command '$cmd'" >&2
        usage >&2
        exit 2
        ;;
    esac
  '';
}
