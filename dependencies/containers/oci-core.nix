# Builds the wwn-oci crate: the universal, cross-platform OCI image-management
# core (registry v2 pull, CAS store, manifest parse, rootfs unpack). Pure
# userspace - no container execution - so it is safe/compliant on every target.
#
# This derivation builds the HOST binary + runs the unit tests (phase 3: "unit
# test on macOS"). Cross-compiled variants for Apple/Android targets are wired
# through wwn-toolchain's rust platforms later (see README port plan).
{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "wwn-oci";
  version = "0.1.0";

  src = lib.cleanSource ./oci-core;

  cargoLock.lockFile = ./oci-core/Cargo.lock;

  # Run the crate's unit tests as part of the build (offline: reference/digest/
  # store/unpack tests need no network; the registry client is exercised by the
  # pure challenge/base64 parsers).
  doCheck = true;

  meta = with lib; {
    description = "Universal OCI image management for Wawona (pull/store/unpack, no exec)";
    mainProgram = "wwn-oci";
    platforms = platforms.unix;
  };
}
