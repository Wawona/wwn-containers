# Phase A spike — desktop environments in containers (KDE Plasma)

De-risks the two unknowns blocking the KDE-Plasma-in-a-container plan before any
product code:

1. **waypipe `--vsock` direction** — guest binds (`server`), host dials in via
   Containerization `dialVsock` and hands the raw fd pair to the host waypipe
   client (`--socket-fds`). Flagged unverified since Phase 0.
2. **KWin nested viability** — `kwin_wayland --platform wayland` as a regular
   Wayland client of the pipe.

Everything in this directory is **spike code**. Nothing in the main flake, the
production `wwn-containerd`, or Wawona is touched. Working parts land in
Phase B (`wwn-containerd` relay) and Phase C (the real Plasma image).

## Topology under test

```
[container (OCI image, aarch64-linux)]
  waypipe --no-gpu --vsock -s <port> server -- /session.sh <mode>
    ├─ mode=flower: weston-flower          (trivial client)
    └─ mode=kwin:   kwin_wayland --platform wayland  (nested compositor)
        │ binds AF_VSOCK VMADDR_CID_ANY:<port> in-guest
        ▼
[host: wwn-containerd-spike (Swift)]
  container.dialVsock(<port>) -> fd  →  dup(R), dup(W)
  waypipe --socket-fds R,W client   →  inherited WAYLAND_DISPLAY → Wawona wayland-0
```

## Why the fd handoff is the only path (verified this session)

- macOS has **no `/dev/vsock`**; the container VM's vsock is reachable only
  through the framework API (`LinuxContainer.dialVsock(port:) -> FileHandle`,
  vendored checkout `Sources/Containerization/LinuxContainer.swift:1066`).
- The framework's unix-socket relay (`relayUnixSocket` →
  `UnixSocketRelay` → `BidirectionalRelay`) is a **byte pipe** that strips
  `SCM_RIGHTS` (no recvmsg cmsg handling), so `wl_shm` fd-passing cannot
  survive it — waypipe must sit directly on the dialed fd.
- The Rust port's `--vsock` is **Linux-only** (`cfg!(not(target_os = "linux"))`
  rejection in `src/main.rs`), so the host cannot use `--vsock` either.

## Findings that adjust the plan (important)

1. **The bundled host waypipe cannot do `--socket-fds` today.**
   `wwn-waypipe/dependencies/libs/waypipe/macos.nix` patches the Rust port so
   the *enum* exists, but its `socket_connect` arm is
   `unreachable!("SplitFD is not used on macOS")` — the flag would panic.
   Worse, its `--socket-fds` parsing patch targets a manual arg loop that does
   not exist in the v0.11.0 Rust port (it uses **clap**), so the flag would not
   even parse. The fix (clap arg + real `SplitFD` arms) is productized as
   `dependencies/containers/macos/waypipe-splitfd.nix` (main flake
   `.#waypipe-splitfd`) — this spike references the same file. **Open decision:
   land the same fix in wwn-waypipe `macos.nix`** (needs that repo's approval),
   then drop the wwn-containers-local variant.
2. **No aarch64-linux builder on this machine.** The container system, kernel
   (`<app-root>/kernels/default.kernel-arm64`), vminit initfs
   (`<app-root>/initfs.ext4`), and `container image load` all exist, but local
   `nix build` for aarch64-linux fails with "platform mismatch"
   (`dockerTools` derivations are target-system). Options: enable the
   Determinate VZ Linux builder, use a remote builder, or build the image in
   CI and copy the tar.gz.
3. Direction semantics are now pinned from source (Rust port v0.11.0):
   guest `-s <port>` + `--vsock` **binds** `VMADDR_CID_ANY:<port>`; host must
   dial in — exactly the topology above. `-s` accepts `[[s]CID:]port`.
4. Guest waypipe from nixpkgs is **0.11.0** (same version family as the host
   Rust port), with `--vsock`; the spike forces `--no-gpu` on the guest so the
   whole pipe stays software-rendered `wl_shm`.

## Layout

| Path | Role |
| --- | --- |
| `flake.nix` | spike flake: guest image + patched host waypipe + harness staging |
| `guest/plasma-spike-image.nix` | aarch64-linux OCI image (waypipe + weston-flower + kwin + qtwayland + dbus) |
| `guest/session.sh` | in-container entrypoint (`flower` / `kwin` modes) |
| `host/WWNContainerSpike/` | SwiftPM harness (dialVsock → dup fds → spawn waypipe client) |
| `host/spike-bridge.nix` | runtime-compile staging wrapper (same model as wwn-containerd) |
| `boot-test.sh` | end-to-end driver + results checklist |

> **Phase B landed.** The SplitFD waypipe build moved to
> `dependencies/containers/macos/waypipe-splitfd.nix` (main flake
> `.#waypipe-splitfd`), and `wwn-containerd` now performs the relay itself when
> `--wayland-vsock-port` is set — the spike harness and this spike's host-waypipe
> output remain for isolated boot-testing (same file, no duplication).

## Run

```bash
# 0. prereqs: Wawona running (a wayland-0 socket), `container system start` done
# 1. guest image (needs an aarch64-linux builder — see findings #2)
nix build ./spike#wawona-plasma-guest-spike
# 2. host side (both build locally on the Mac)
nix build ./spike#waypipe-splitfd
nix build ./spike#wwn-containerd-spike
# 3. boot test
./spike/boot-test.sh flower   # vsock direction test
./spike/boot-test.sh kwin     # nested KWin test
```

The harness mirrors production defaults (kernel/initfs auto-discovered from the
Apple container system store), so `wwn-containerd-spike --help` is the source of
truth for overrides (`--image`, `--vsock-port`, `--waypipe-bin`, …).

## Expected results

- **flower**: a Wawona window with weston-flower's rotating rectangles →
  the whole pipe (vsock direction + fd handoff + SHM fd-passing) works.
- **kwin**: a Wawona window with a KWin desktop (nested backend quirks
  expected: no taskbar/plasmashell — that's Phase C).
- Both: closing the window ends the session; `wwn-containerd-spike` tears the
  container down cleanly.
