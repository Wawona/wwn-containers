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

## Container-in-VM (non-macOS execution)

`dependencies/containers/container-in-vm/guest-module.nix` extends the `wwn-vms`
mobile NixOS guest with an in-guest OCI runtime (crun/podman). The host shares an
OCI bundle (produced by `wwn-oci`) into the guest over virtiofs; the guest runs
it with `crun` against a headless cage compositor whose framebuffer waypipe
streams to Wawona over vsock. Exposed as `nixosConfigurations.wawona-container-guest`.
This is the execution backend for iOS/iPadOS/visionOS/tvOS (QEMU-TCTI) and one of
the two Android paths.

## Native `container` CLI (scaffold)

Wawona's native terminals + [`wwn-zsh`](../wwn-zsh) must expose a first-class
`container` command so a user can **manage and run OCI containers from a shell on
every target** (the whole Apple ecosystem + Android) and boot them from inside
native clients like on a real computer. It is the terminal front-end to the same
substrate the GUI uses (Settings → Containers, Machine profile → Containers) —
`wwn-oci` for image management plus the per-target execution backend.

- Scaffold: `dependencies/containers/cli/container-cli.nix` → the `container-cli`
  flake package (`nix run .#container-cli -- --help`) and the `container-cli`
  registry entry (per-target, cross-built later). The command surface exists now;
  every subcommand is a stub that exits non-zero.
- **Requirement of record + design:**
  [`Wawona/docs/2026-container-cli.md`](https://github.com/Wawona/Wawona/blob/main/docs/2026-container-cli.md).
  **Not implemented yet** — scaffold only.

## Android rootless backend (proot)

`dependencies/containers/android/proot-runner.nix` runs a `wwn-oci`-unpacked
rootfs **rootless + jitless** via proot (ptrace chroot, Termux model) - the
lighter Android path when full VM isolation isn't required. The heavier path is
container-in-VM via the `wwn-vms` Android QEMU engine. Both are Play-Store
compliant.

## Port plan

1. OCI core in Rust: pull/auth/digest-verify, CAS layer store, manifest/config
   parse, rootfs unpack. Unit-test on macOS. Cross-compile via `wwn-toolchain`.
2. macOS `containerization.framework` backend (Swift bridge).
3. Container-in-VM: run OCI rootfs inside `wwn-vms` guests (mobile + Android).
4. Android rootless proot/namespace backend.
5. Replace `dependencies/containers/stub.nix` with per-platform derivations;
   expose `oci-image-*` and `oci-runtime-*` packages.
6. Native `container` CLI (wwn-zsh / native terminals) over `wwn-oci` + the
   per-target execution backend, on every target. Scaffolded; see
   `Wawona/docs/2026-container-cli.md`.

## Convention

Follows the [wwn-* porting convention](https://github.com/Wawona/Wawona/blob/main/docs/2026-wwn-porting-convention.md).
