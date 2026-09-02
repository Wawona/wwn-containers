# wwn-containers

[![CI](https://github.com/Wawona/wwn-containers/actions/workflows/ci.yml/badge.svg)](https://github.com/Wawona/wwn-containers/actions/workflows/ci.yml)

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
   - **iOS / iPadOS**: **Mode A** container-in-VM on jitless `wwn-vms`; **Mode B**
     (Sileo Mode B IPA only) container-in-VM on JIT UTM — see
     [`docs/MODE-A-B.md`](docs/MODE-A-B.md). Never ship Mode B in App Store.
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
- `hub` - Docker Hub discovery client (search + tags). Hub's JSON API is not
  part of the OCI distribution spec, so it lives apart from `registry`;
  metadata-only HTTPS GET, no image data.

CLI: `wwn-oci pull alpine:3.20 --dest ./img`, `wwn-oci resolve <ref>`,
`wwn-oci search python`, `wwn-oci tags python`.

## Apple `container` CLI (macOS only, swiftpm2nix)

The official Apple [container](https://github.com/apple/container) CLI is
packaged as `.#apple-container`. **macOS / Darwin only** — registry entries for
every other platform throw. Build instructions, the insomnia-creator flake
notes, and the v7-tolerant swiftpm2nix lock:

[`docs/apple-container.md`](docs/apple-container.md)

```bash
nix build .#apple-container
./result/bin/container --help
```

## Prebaked desktop OCI (`wawona-container-desktop`)

Linux package (build on `aarch64-linux` or via
`nix build .#packages.aarch64-linux.wawona-container-desktop` from Darwin when
cross is available). Includes weston-flower, sway, Hyprland, foot, labwc, weston,
kwin, and ghostty when present in nixpkgs. Wawona CLI recipes
(`Wawona run flower|sway|hyprland|ghostty`) invoke those binaries **without**
`nix shell` at Start.

```bash
nix build .#packages.aarch64-linux.wawona-container-desktop
container import ./result --reference wawona-container-desktop:latest
container run --rm --image-archive ~/.local/share/wwn-oci/oci-layout/<manifest-hex> \
  wawona-container-desktop:latest weston-flower
```

Wawona CLI recipes auto-attach `--image-archive` when that import is present
under `~/.local/share/wwn-oci` (avoids a Docker Hub pull for a local-only tag).

Optional product-build: copy the OCI layout into
`Wawona.app/Contents/Resources/oci/wawona-container-desktop/` so Machines can
use `--image-archive` with no registry pull.

## macOS execution backend (wwn-containerd)

`dependencies/containers/macos` is a SwiftPM package (`wwn-containerd`) built on
Apple's [Containerization](https://github.com/apple/containerization) framework:
each container runs in its own lightweight VM with `vminitd` (gRPC over vsock).
`nix build .#wwn-containerd` compiles the Swift binary at build time (host
Xcode + macOS SDK, `__noChroot`) and installs a prebuilt, ad-hoc signed
`bin/wwn-containerd` into the Nix store. Wawona bundles that binary into
`Wawona.app/Contents/Resources/bin/`; Machines Start never runs `swift build`
or writes to `~/.cache/wwn-containerd`.
Direct/notarized channel only (not Mac App Store viable). `--wayland-vsock-port`
bridges the guest's Wayland session into Wawona for **any** OCI image — no
special image required:

- **guest side**: the host's Linux waypipe (nixpkgs, aarch64-linux) is injected
  into the container as a read-only file mount at `/usr/local/bin/waypipe`
  (framework `FileMountContext` transforms file `Mount.share`s into virtiofs +
  bind mounts), and the command is wrapped as
  `/usr/local/bin/waypipe --vsock -s <port> server -- <cmd>` (GPU/dmabuf
  allowed; `--no-gpu` only when `WAWONA_WAYPIPE_NO_GPU=1` / Disable GPU), with a
  sh preamble that creates `XDG_RUNTIME_DIR`.
- **host side**: after `container.start()` the backend dials the container's
  vsock port (`dialVsock`) and spawns the host
  `waypipe --socket-fds R,W client` on the raw fd pair (inheriting
  `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` and Vulkan ICD env), so the guest session
  appears as a Wawona window.

`--waypipe-guest-bin <path>` (or `WAWONA_WAYPIPE_GUEST`) supplies the guest
waypipe binary; the host waypipe must support SplitFD (`--socket-fds`) —
product path is wwn-waypipe macos.nix (IOSurface dmabuf + SplitFD), bundled as
`waypipe-fds`. Resolve via `WWNP_WAYPIPE_BIN` or PATH. See
`dependencies/containers/macos/waypipe-splitfd.nix` for the SHM-only fallback.
wwn-waypipe-upstream decision.

### GPU / OpenGL / Vulkan (macOS containers)

Apple Containerization VMs expose **no `/dev/dri`**. Guest waypipe's default
GPU/dmabuf path `dlopen`s `libvulkan.so.1`; if that fails it **fatals the
Wayland display** (every client dies, not only GL). `waypipe-guest-root` must
therefore ship `libvulkan.so.1` plus a lavapipe ICD under
`/opt/wawona-waypipe/` (see `waypipe-guest-root.nix`). Until that tree is
present, `wwn-containerd` auto-falls back to `--no-gpu` (SHM) on **both**
guest server and host client, and logs a one-line warning.

OpenGL apps still need a guest GLES/GL stack that can allocate buffers without
a DRM node (software Mesa llvmpipe, or lavapipe+zink), or a future virtio-gpu.
Proven on Alpine over GPU waypipe: `apk add mesa-egl mesa-dri-gallium
weston-clients` then `LIBGL_ALWAYS_SOFTWARE=1 weston-simple-egl` (~57 fps in
CLI smoke). `eglinfo` Wayland platform reports `llvmpipe`. Host IOSurface
dmabuf remoting is ready once the guest produces dmabufs; soft GL may still
travel as SHM inside the GPU waypipe session.

Vulkan: guest-root lavapipe is for **waypipe's** dmabuf path. Image
`vulkaninfo --summary` works headless after `unset WAYLAND_SOCKET` (with the
socket set, some vulkan-tools builds segfault during WSI probe). Bookworm
`vkcube` is X11-only; prefer a Wayland WSI cube when packaging demos.

`wwn-containerd` does **not** export `LD_LIBRARY_PATH=/opt/wawona-waypipe/lib`
into the guest session. That tree is glibc; Alpine/musl `apk` and image
binaries break if they load those libs (`__snprintf_chk: symbol not found`).
Guest waypipe finds Vulkan via its own `RPATH` plus `VK_ICD_FILENAMES`. The
user command is started with `env -u VK_ICD_FILENAMES -u VK_DRIVER_FILES` so
image Mesa is not forced onto the nix lavapipe ICD. Musl images can
`apk add mesa-*` / `vulkan-tools` for client GL/VK; glibc images may set
`LD_LIBRARY_PATH` / `VK_ICD_FILENAMES` themselves if they want the bundled
lavapipe.

Known limits (v1): guest waypipe is glibc/patchelf (not a musl static build);
image entry command must be explicit (image-default Cmd fallback — follow-up);
X11 apps need in-guest XWayland (`waypipe --xwls` — follow-up).

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
