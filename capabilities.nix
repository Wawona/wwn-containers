# Per-target container capability matrix + eval-time assertions ("capability
# lane"). CI checks this with `nix eval .#lib.capabilities`. Cross-checks the
# wwn-vms matrix: real container *execution* needs a Linux kernel, which comes
# either from Apple's Containerization framework (macOS) or a wwn-vms VM.
#
#   ociImage  universal image management (pull/store/unpack) - pure userspace
#   exec      can a container actually execute on this target?
#   backend   "containerization" | "container-in-vm" | "proot" | null
{ vmsCapabilities }:
let
  caps = {
    macos = { ociImage = true; exec = true; backend = "containerization"; };
    ios = { ociImage = true; exec = true; backend = "container-in-vm"; };
    ipados = { ociImage = true; exec = true; backend = "container-in-vm"; };
    tvos = { ociImage = true; exec = true; backend = "container-in-vm"; };
    visionos = { ociImage = true; exec = true; backend = "container-in-vm"; };
    watchos = { ociImage = true; exec = false; backend = null; };
    android = { ociImage = true; exec = true; backend = "container-in-vm"; };
  };
  targets = builtins.attrNames caps;
  # Execution requires a kernel: macOS Containerization brings its own; every
  # other executing target must have a wwn-vms VM available.
  execImpliesKernel =
    t:
    !caps.${t}.exec || caps.${t}.backend == "containerization" || vmsCapabilities.${t}.vm;
in
# OCI image management is universal + always compliant (no target excluded).
assert builtins.all (t: caps.${t}.ociImage) targets;
# watchOS: image management only, never execution.
assert caps.watchos.exec == false;
# macOS uses Apple's per-container VM framework.
assert caps.macos.backend == "containerization";
# Cross-dep invariant: no execution without a kernel (Containerization or a VM).
assert builtins.all execImpliesKernel targets;
caps
