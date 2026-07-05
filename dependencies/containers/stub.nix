# Port stub for wwn-containers. Evaluates cleanly (so registryFragment merges and
# CI can enumerate the target) but fails the build with a clear message until the
# real backend lands. Replace with per-platform derivations:
#
#   oci-image    Rust OCI core: registry v2 pull/auth/digest-verify,
#                content-addressable layer store, manifest/config parse, rootfs
#                unpack. Pure userspace -> builds for every target.
#   oci-runtime  macos    -> Apple containerization.framework (vminitd, gRPC/vsock)
#                ios/etc  -> container-in-VM via wwn-vms (crun/podman in-guest)
#                android  -> QEMU container-in-VM or rootless proot/namespaces
#                watchos  -> N/A (image management only); see COMPLIANCE.md
{ ... }:
throw "wwn-containers: backend is not implemented yet (scaffold only). See README.md port plan and COMPLIANCE.md."
