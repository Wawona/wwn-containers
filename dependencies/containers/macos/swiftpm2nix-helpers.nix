# swiftpm2nix helpers, adapted from nixpkgs
# pkgs/development/compilers/swift/swiftpm2nix/support.nix
#
# Stock nixpkgs swiftpm2nix only accepts workspace-state versions 5–6 and
# rewrites Package.resolved to the SwiftPM v1 pin format. Apple's `container`
# (Swift 6.2) writes workspace-state v7 + Package.resolved v3 (`originHash`).
# This helper accepts v5–v7 and leaves the project's own Package.resolved in
# place so `swift build --skip-update` can use the prefetched checkouts.
{
  lib,
  fetchgit,
}:
let
  inherit (lib)
    concatStrings
    listToAttrs
    mapAttrsToList
    nameValuePair
    ;
in
{
  helpers =
    generated:
    let
      inherit (import generated) workspaceStateFile hashes;
      workspaceState = lib.importJSON workspaceStateFile;
      version = workspaceState.version;
    in
    assert version >= 5 && version <= 7;
    rec {
      sources = listToAttrs (
        map (
          dep:
          nameValuePair dep.subpath (fetchgit {
            url = dep.packageRef.location;
            rev = dep.state.checkoutState.revision;
            sha256 = hashes.${dep.subpath};
            fetchSubmodules = true;
          })
        ) workspaceState.object.dependencies
      );

      configure = ''
        mkdir -p .build/checkouts
        install -m 0600 ${workspaceStateFile} ./.build/workspace-state.json
      ''
      + concatStrings (
        mapAttrsToList (name: src: ''
          ln -s '${src}' '.build/checkouts/${name}'
        '') sources
      )
      + ''
        swiftpmMakeMutable() {
          local orig="$(readlink .build/checkouts/$1)"
          rm .build/checkouts/$1
          cp -r "$orig" .build/checkouts/$1
          chmod -R u+w .build/checkouts/$1
        }
      '';
    };
}
