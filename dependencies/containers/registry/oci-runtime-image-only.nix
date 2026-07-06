# watchOS / wearOS: OCI image management only (no Linux kernel → no execution).
{ pkgs, lib ? pkgs.lib, ... }:
pkgs.writeTextDir "README" ''
  wwn-containers: image management only on this target (COMPLIANCE.md).

  Users can pull/inspect/store OCI images via wwn-oci. Container execution requires
  a Linux kernel and is not available on watchOS/wearOS.
''
