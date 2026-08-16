# Apple's `container` CLI and Containerization.framework are macOS-only
# (Virtualization.framework, Apple silicon, macOS 15+ / 26 recommended).
# Other Wawona targets use container-in-VM via wwn-vms, never this engine.
# See Wawona/docs/wwn-repo-dag.md — this key must not enter L0 baseRegistry.
{ pkgs ? null, lib ? null, ... }:
throw "apple-container / Containerization.framework is macOS-only. Use container-in-VM (wwn-vms) on this target."
