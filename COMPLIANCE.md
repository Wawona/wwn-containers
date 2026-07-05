# wwn-containers App Store / platform compliance

Honest, per-target posture. Image management is universal and always compliant;
execution is gated on whether a Linux kernel can legally run.

| Target | OCI image mgmt | Execution | Backend | Store posture |
| --- | --- | --- | --- | --- |
| macOS (direct/notarized) | Yes | Yes | Apple `containerization.framework` (per-container VM) or container-in-`wwn-vms` | Direct/notarized. Needs `com.apple.security.virtualization`. |
| macOS (Mac App Store) | Yes | **No** | - | Image management only (pure userspace); execution needs VM spawning (forbidden under MAS). |
| iOS | Yes | Yes | container-in-VM via `wwn-vms` QEMU-TCTI (crun/podman in-guest) | Image mgmt is pure userspace. Execution rides the compliant jitless VM; guest is bundled/ODR data. |
| iPadOS | Yes | Yes | container-in-VM | Same as iOS. |
| visionOS | Yes | Yes | container-in-VM | Same as iOS. |
| tvOS | Yes | Limited | container-in-VM (minimal guest) | Tight RAM; may be image-management-only. |
| watchOS | Yes | **No** | - | Image management only. No VM, so no execution. |
| Android | Yes | Yes | container-in-VM (QEMU/AVF) or rootless proot/namespaces | proot path is rootless + jitless; Play-Store compliant. |

## Hard rules

- **Image management is universal and always compliant.** Pulling, verifying,
  storing, and unpacking OCI images is pure userspace with no code execution, so
  it ships on every target including iOS and watchOS.
- **No execution without a kernel.** Running a container requires a Linux kernel:
  Apple's `containerization.framework` on macOS, or a `wwn-vms` VM everywhere
  else. Where no VM is allowed (watchOS, MAS), we ship image management only - we
  do not fake execution.
- **No JIT on Apple targets.** The container-in-VM path inherits `wwn-vms`'
  jitless QEMU-TCTI on iOS/iPadOS/tvOS/visionOS.
- **Rootless where possible.** The Android proot/user-namespace backend needs no
  root and no JIT.
- **No downloaded executables on Apple targets.** Guest kernels/rootfs and the
  runtime are bundled resources; only OCI *image data* is fetched at runtime.

## Native `container` CLI

The `container` command (wwn-zsh / native terminals) is a front-end over the same
substrate, so it inherits every rule above. Image-management subcommands
(`pull`/`images`/`inspect`/`rmi`) are available on **all** targets; lifecycle
subcommands (`run`/`exec`/...) are gated by the Execution column of the matrix and
must fail cleanly (never fake execution) where no kernel is available (watchOS,
Mac App Store). See [Wawona/docs/2026-container-cli.md](https://github.com/Wawona/Wawona/blob/main/docs/2026-container-cli.md).
Scaffold only — not implemented yet.
