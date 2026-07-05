# wwn-containers

Wawona's **OCI container substrate**, split out of the Wawona repo so container
support is developed, versioned, and CI'd independently and consumed by Wawona as
a flake input. Aligns with `wwn-toolchain` and depends on
[`wwn-vms`](../wwn-vms).

Two layers:

1. **Universal OCI image management** (all targets, including iOS and watchOS):
   pure-userspace registry v2 client (pull, token auth, digest verify),
   content-addressable layer store, manifest/config parse, rootfs unpack. No
   execution, no kernel needed - so it is fully App-Store-compliant everywhere.
   This is the "true OCI image management" that works even where no container can
   run.
2. **Execution backends**, only where a Linux kernel is available:
   - **macOS** (direct): Apple
     [`containerization.framework`](https://github.com/apple/containerization) -
     each container in a lightweight VM (`vminitd`, gRPC over vsock). Fallback:
     container-in-`wwn-vms` NixOS VM.
   - **iOS / iPadOS / visionOS / tvOS**: **container-in-VM** - run the OCI rootfs
     inside the `wwn-vms` QEMU-TCTI NixOS guest (crun/podman in-guest), surfaced
     over vsock + waypipe.
   - **Android**: container-in-VM (QEMU) for full isolation, plus a rootless
     **proot / user-namespace** backend (Termux-style, no root, jitless) for
     lighter workloads.
   - **watchOS**: image management only; no execution.

> **Status: SKELETON.** Flake + `registryFragment` + this port plan +
> `COMPLIANCE.md`. Build stubs (`dependencies/containers/stub.nix`) fail with a
> clear message. Real backends are downstream.

## Why depend on wwn-vms

A real container needs a Linux kernel. On macOS Apple provides one per container
via `containerization.framework`; on every other non-macOS target the only way
to get a kernel is a VM, which is exactly what `wwn-vms` ships. So the runtime
layer sits on top of `wwn-vms` (container-in-VM), while the image layer stands
alone.

## Language split

- **Rust** for the cross-platform OCI core (cross-compiles through
  `wwn-toolchain`, matches Wawona's Rust core).
- **Swift** for the macOS `containerization.framework` bridge.

## Port plan

1. OCI core in Rust: pull/auth/digest-verify, CAS layer store, manifest/config
   parse, rootfs unpack. Unit-test on macOS. Cross-compile via `wwn-toolchain`.
2. macOS `containerization.framework` backend (Swift bridge).
3. Container-in-VM: run OCI rootfs inside `wwn-vms` guests (mobile + Android).
4. Android rootless proot/namespace backend.
5. Replace `dependencies/containers/stub.nix` with per-platform derivations;
   expose `oci-image-*` and `oci-runtime-*` packages.

## Convention

Follows the [wwn-* porting convention](https://github.com/Wawona/Wawona/blob/main/docs/2026-wwn-porting-convention.md).
