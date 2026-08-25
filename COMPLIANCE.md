# wwn-containers App Store / platform compliance

Honest, per-target posture. Full Mode A/B plan: [`docs/MODE-A-B.md`](./docs/MODE-A-B.md)
and [Wawona `mode-a-b.md`](https://github.com/Wawona/Wawona/blob/development/docs/mode-a-b.md).

| Target | OCI image mgmt | Mode A execution | Mode B execution |
| --- | --- | --- | --- |
| macOS (direct) | Yes | Apple Containerization and/or container-in-`wwn-vms` | Same privileged channel |
| macOS (MAS) | Yes | **No** | N/A |
| iOS / iPadOS / visionOS | Yes | container-in-VM on **jitless** UTM-SE/`wwn-vms` A | container-in-VM on **JIT** UTM (`wwn-vms` B). Sileo Mode B IPA only |
| tvOS / watchOS | Yes (mgmt) | **No** run (forbidden machine kind) | **No** |
| Android | Yes | container-in-VM and/or rootless proot | Optional root Mode B |

## Hard rules

- Image management is universal and Mode A–safe.
- **iOS Mode A run = jitless VM only.** Mode B JIT run never ships in App Store.
- Design both backends in-tree; select by product flavor.
- **No JIT on Apple Mode A.** Inherit `wwn-vms` Mode A ceiling.
- Wasm Runtime packages (`wpm`) are a different product surface — not `container pull`.
- Not a substitute for jailbreak APT on Mode B devices.
