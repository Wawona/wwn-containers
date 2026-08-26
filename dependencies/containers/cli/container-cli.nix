# Native `container` CLI - the command Wawona's native terminals + wwn-zsh
# expose so a user can manage and run OCI containers from a shell "like on a
# real computer".
#
# IMPLEMENTED (this file is no longer a scaffold):
#   * image management (pull/images/rmi/inspect/resolve) -> wwn-oci (Rust),
#     universal + App-Store-compliant on every target.
#   * search/tags -> wwn-oci Docker Hub metadata client (pure HTTPS GET,
#     no image data; Hub API is outside the OCI distribution spec).
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
      import <path>         add an image from disk (docker-archive tar.gz,
                            OCI-archive tar, or OCI layout dir; auto-detected)
                            --reference <name:tag> to name it
      images                list pulled images
      rmi <ref>             remove an image (keeps shared blobs)
      inspect <ref>         show image manifest/config/layers/rootfs
      resolve <ref>         print the parsed reference components
      search <query>        search Docker Hub for images (metadata only)
      tags <repo>           list tags of a Docker Hub repository
                            (--matches <substr> filters tags client-side,
                             --limit/--page page through them)

    LIFECYCLE (only where a Linux kernel is available):
      run <ref> [cmd...]    boot a per-container VM and run a process (macOS:
                            Apple Containerization framework via wwn-containerd)
      run flags (macOS backend):
        -k|--kernel <path>  Linux kernel for the VM (else WAWONA_VM_KERNEL / auto)
        --initfs <path>     prebuilt vminitd ext4 initfs (else vminit:latest)
        --app-root <path>   Apple container system app-data root (else
                            $CONTAINER_APP_ROOT / ~/Library/Application Support/com.apple.container)
        -m|--memory <MiB>   guest memory (default 1024)
        -c|--cpus <n>       vCPUs (default 2)
        --fs-size <MiB>     rootfs block size (default 2048)
        --read-only         mount the rootfs read-only
        --init              run an init process (signal fwd + zombie reaping)
        --id <name>         container id (default wawona)
        --wayland-vsock-port <n>  guest vsock port to bridge to Wawona (0 = off)
        --waypipe-guest-bin <path>  host path to the Linux waypipe binary to
                            inject into the guest (else $WAWONA_WAYPIPE_GUEST)
        --image-archive <path>  run from a local OCI layout dir instead of a
                            registry reference (wwn-oci import emits one)
        --rm                accepted no-op: every run is one-shot (container is
                            always removed when it stops)
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

    # Prefer wwn-containerd colocated with this script (Wawona.app Resources/bin).
    resolve_wwn_containerd() {
      local script_dir
      script_dir="$(cd "$(dirname "$0")" && pwd)"
      if [ -x "$script_dir/wwn-containerd" ]; then
        printf '%s\n' "$script_dir/wwn-containerd"
        return 0
      fi
      command -v wwn-containerd
    }

    case "$cmd" in
      -h|--help|help)
        usage
        exit 0
        ;;
      pull|images|rmi|inspect|resolve|search|tags|import)
        exec wwn-oci "$cmd" "$@"
        ;;
      run)
        if [ "$#" -eq 0 ]; then
          echo "container: run needs an image reference" >&2
          exit 2
        fi
        # Parse the run flags the macOS backend (wwn-containerd) can honor,
        # before the image ref. Flags the backend cannot honor yet are rejected
        # explicitly - never silently dropped (COMPLIANCE: no fake execution).
        KERNEL_ARG=""
        INITFS_ARGS=()
        WCD_ARGS=()
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -k|--kernel) KERNEL_ARG="$2"; shift 2 ;;
            --initfs) INITFS_ARGS=(--initfs "$2"); shift 2 ;;
            --app-root) WCD_ARGS+=(--app-root "$2"); shift 2 ;;
            -m|--memory) WCD_ARGS+=(--memory "$2"); shift 2 ;;
            -c|--cpus) WCD_ARGS+=(--cpus "$2"); shift 2 ;;
            --fs-size) WCD_ARGS+=(--fs-size "$2"); shift 2 ;;
            --read-only) WCD_ARGS+=(--read-only); shift ;;
            --init) WCD_ARGS+=(--init); shift ;;
            --id) WCD_ARGS+=(--id "$2"); shift 2 ;;
            --wayland-vsock-port) WCD_ARGS+=(--wayland-vsock-port "$2"); shift 2 ;;
            --waypipe-guest-bin) WCD_ARGS+=(--waypipe-guest-bin "$2"); shift 2 ;;
            --image-archive) WCD_ARGS+=(--image-archive "$2"); shift 2 ;;
            # wwn-containerd is one-shot: the container is always removed after
            # it stops, so --rm is accepted as a no-op for CLI compatibility.
            --rm) shift ;;
            --mount|-v|--volume|-p|--publish|--publish-socket|--shm-size|--platform|--network|--env|-e|--dns*|--cap-*|--label|--entrypoint|--tmpfs|--rosetta|--virtualization|--ssh)
              echo "container: '$1' is not supported by the macOS backend yet (wwn-containerd)." >&2
              exit 3
              ;;
            --) shift; break ;;
            -*) echo "container: unknown run flag '$1'" >&2; exit 2 ;;
            *) break ;;
          esac
        done
        REF="$1"
        shift || true
        # WAWONA_VM_INITFS env is the flag-less equivalent of --initfs.
        if [ "''${#INITFS_ARGS[@]}" -eq 0 ] && [ -n "''${WAWONA_VM_INITFS:-}" ]; then
          INITFS_ARGS=(--initfs "$WAWONA_VM_INITFS")
        fi
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
        # Apple's Containerization reference parser requires an explicit tag or
        # digest (docker.io/nixos/nix is rejected; docker.io/nixos/nix:latest
        # is not).
        case "$REF" in
          *@*|*:* ) ;;
          *) REF="$REF:latest" ;;
        esac
        case "$(uname -s):$BACKEND" in
          Darwin:auto|Darwin:containerization)
            WWN_CONTAINERD="$(resolve_wwn_containerd || true)"
            if [ -z "$WWN_CONTAINERD" ] || [ ! -x "$WWN_CONTAINERD" ]; then
              echo "container: wwn-containerd backend not available in this build." >&2
              exit 3
            fi
            KERNEL="''${KERNEL_ARG:-}"
            if [ -z "$KERNEL" ]; then
              if ! KERNEL="$(find_kernel)"; then
                echo "container: no Linux kernel found for the VM." >&2
                echo "  set WAWONA_VM_KERNEL=/path/to/vmlinux (or install one via" >&2
                echo "  Apple's \`container system start --enable-kernel-install\`)." >&2
                exit 3
              fi
            fi
            exec "$WWN_CONTAINERD" run -i "$REF" -k "$KERNEL" "''${INITFS_ARGS[@]}" "''${WCD_ARGS[@]}" "$@"
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
