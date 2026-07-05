# Native `container` CLI - SCAFFOLD ONLY (not implemented yet).
#
# The command that Wawona's native terminals + wwn-zsh expose so a user can
# manage and run OCI containers from a shell "like on a real computer", on every
# target (the whole Apple ecosystem + Android). Backend per target:
#
#   macOS                Apple containerization.framework (wwn-containerd)
#   iOS/iPadOS/visionOS  container-in-VM (wwn-vms QEMU-TCTI guest, crun in-guest)
#   tvOS                 container-in-VM (minimal guest) or image-mgmt only
#   watchOS              image management only (no execution)
#   Android              container-in-VM (QEMU/AVF) or rootless proot
#
# This scaffold ships the command surface NOW (so wwn-zsh / native clients can
# wire the name and Settings can reference it) but every subcommand is a stub
# that prints its intent and exits non-zero. Real behavior is tracked in
# Wawona/docs/2026-container-cli.md and lands later.
{ pkgs }:
pkgs.writeShellApplication {
  name = "container";
  runtimeInputs = [ ];
  text = ''
    # wwn-containers native CLI (SCAFFOLD). Backend selection is driven by
    # WAWONA_CONTAINER_BACKEND when set by the host (see WWNContainerRunner);
    # otherwise it is inferred per platform at implementation time.
    BACKEND="''${WAWONA_CONTAINER_BACKEND:-auto}"

    usage() {
      cat <<'EOF'
    container - Wawona native OCI container CLI (SCAFFOLD - not yet implemented)

    USAGE:
      container <command> [args]

    IMAGE MANAGEMENT (universal, planned via wwn-oci - works on every target):
      pull <ref>            download an OCI image into the local store
      images                list images in the local store
      rmi <ref>             remove an image
      inspect <ref>         show image manifest/config

    LIFECYCLE (only where a Linux kernel is available - see COMPLIANCE.md):
      run <ref> [cmd...]    create + start a container, attach to Wawona
      exec <id> <cmd...>    run a process in a running container
      ps                    list containers
      start|stop <id>       start / stop a container
      rm <id>               remove a container
      logs <id>             stream container logs

    Per-target backend: macOS = Apple containerization.framework; Apple mobile =
    container-in-VM (wwn-vms); Android = container-in-VM or rootless proot;
    watchOS = image management only.

    STATUS: scaffold. Design + requirements: Wawona/docs/2026-container-cli.md
    EOF
    }

    if [ "$#" -eq 0 ]; then
      usage
      exit 2
    fi

    cmd="$1"
    shift || true

    case "$cmd" in
      -h|--help|help)
        usage
        exit 0
        ;;
      pull|images|rmi|inspect|run|exec|ps|start|stop|rm|logs)
        echo "container: '$cmd' is not implemented yet (backend=$BACKEND)." >&2
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
