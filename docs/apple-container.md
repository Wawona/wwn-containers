# Apple `container` CLI (macOS only)

Wawona's macOS execution engine for OCI containers is Apple
[container](https://github.com/apple/container) /
[Containerization](https://github.com/apple/containerization): each container
is a lightweight Linux VM on Apple silicon.

This is **not** available on iOS, iPadOS, tvOS, watchOS, visionOS, Android, or
Linux. Those targets use container-in-VM (`wwn-vms`) or image-management only.
`wwn-toolchain` `baseRegistry` throws if `apple-container` / `containerization`
are added at L0. See `Wawona/docs/wwn-repo-dag.md`.

## Nix flake (identified)

The [insomnia-creator/container](https://github.com/insomnia-creator/container)
fork of `apple/container` adds a Nix flake that builds the CLI with host
`/usr/bin/swift` and vendors SwiftPM deps from `Package.resolved` via
`builtins.fetchGit`.

```text
flake.nix
  supportedSystems = [ "aarch64-darwin" "x86_64-darwin" ]
  packages.<system>.container / default
  nix build --impure    # host Swift + fetchGit
  nix run --impure
```

That flake is Darwin-only. `--impure` is required there because of
`builtins.fetchGit` and `/usr/bin/swift`.

## What we ship (`swiftpm2nix`)

Stock nixpkgs [`swiftpm2nix`](https://ryantm.github.io/nixpkgs/languages-frameworks/swift/)
only accepts workspace-state **v5–v6** and rewrites `Package.resolved` to the
old v1 pin format. Apple's `container` (Swift 6.2) writes **workspace-state v7**
and `Package.resolved` v3 (`originHash`).

`wwn-containers` therefore keeps a swiftpm2nix-**compatible** lock and a
v7-tolerant helper:

| Path | Role |
|---|---|
| `dependencies/containers/macos/swiftpm2nix/` | Generated lock (`default.nix` hashes + `workspace-state.json`) |
| `dependencies/containers/macos/swiftpm2nix-helpers.nix` | nixpkgs helper, v5–v7, keeps the project's `Package.resolved` |
| `dependencies/containers/macos/apple-container.nix` | macOS recipe (`assert` Darwin) |
| `dependencies/containers/macos/apple-container-forbidden.nix` | throw on every other platform |
| `scripts/update-apple-container-swiftpm2nix.sh` | regenerate the lock |

Pinned source: **apple/container 1.2.2**
(`0190097d06df0b9065f4c2d2c7873c649d81d493`).

The Nix build is **pure**: it stages sources + hashed `fetchgit` checkouts.
Host Xcode Swift compiles the CLI on first run (Containerization needs the
macOS 26 SDK), same model as `wwn-containerd`.

## Build

From `wwn-containers` on a Mac with Xcode 26 (macOS 15+; 26 recommended):

```bash
nix build .#apple-container
./result/bin/container --help
```

First invocation compiles with `/usr/bin/swift` (deps already in the Nix store;
no GitHub fetch). Subsequent runs reuse `$XDG_CACHE_HOME/wwn-apple-container`.

Reference build from the upstream flake (impure):

```bash
git clone https://github.com/insomnia-creator/container.git
cd container
nix build --impure
./result/bin/container --help
```

## Test (OCI + run)

The CLI talks to the Apple container system service. Start it once (needs the
signed helpers from a `make install` / official pkg, or an already-running
`container system`):

```bash
container system start
# resolve / pull from an OCI registry
./result/bin/container image pull python:3.12-slim
./result/bin/container image list
# run
./result/bin/container run --rm python:3.12-slim python -c 'print("hello")'
```

`container image` has no Docker-Hub "search" verb; pull + list is the OCI
surface. `container registry` manages logins.

## Regenerate the lock

```bash
# optional: nix-shell -p nix-prefetch-git
scripts/update-apple-container-swiftpm2nix.sh <apple-container-git-rev>
# then bump fetchFromGitHub rev + hash in apple-container.nix
```
