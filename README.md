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

> **Status: OCI core landed; execution backends downstream.** The universal
> image-management core (`wwn-oci`, Rust) is implemented and builds/unit-tests as
> `nix build .#wwn-oci` (registry v2 pull + token auth, digest-verified CAS
> store, OCI/Docker manifest+index parse with platform selection, layer unpack
> with whiteouts). Execution backends (`dependencies/containers/stub.nix`) still
> `throw` until they land.

## wwn-oci (the OCI core)

Rust crate at `dependencies/containers/oci-core`:

- `reference` - image reference parsing (Docker Hub `library/` + `:latest`
  defaults, custom registries, `@digest` pinning).
- `registry` - Registry v2 client: `WWW-Authenticate` Bearer token negotiation,
  manifest/index fetch with `Docker-Content-Digest` capture, streaming blob GET.
- `digest` - `sha256:` parse + streaming verification (`Sha256Reader`).
- `store` - content-addressable blob store (`blobs/<algo>/<hex>`, atomic
  digest-verified writes).
- `spec` - OCI + Docker image-spec types and media-type constants.
- `unpack` - apply layers to a rootfs with OCI whiteout (`.wh.`, opaque) handling
  and path-traversal guards.

CLI: `wwn-oci pull alpine:3.20 --dest ./img`, `wwn-oci resolve <ref>`.

## macOS execution backend (wwn-containerd)

`dependencies/containers/macos` is a SwiftPM package (`wwn-containerd`) built on
Apple's [Containerization](https://github.com/apple/containerization) framework:
each container runs in its own lightweight VM with `vminitd` (gRPC over vsock).
`nix build .#wwn-containerd` stages the sources purely; the actual `swift build`
(which fetches apple/containerization and needs the macOS 15+ SDK) + ad-hoc
codesign with `com.apple.security.virtualization` happen on first run via the
host Swift toolchain - the same runtime-compile model as wwn-vms' `vz-launcher`.
Direct/notarized channel only (not Mac App Store viable). `--wayland-vsock-port`
forwards the guest's waypipe server into Wawona.

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
