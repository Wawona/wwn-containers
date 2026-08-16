#!/usr/bin/env bash
# Regenerate the swiftpm2nix-style lock for apple/container.
#
# Stock nixpkgs `swiftpm2nix` rejects workspace-state v7 (Apple's container
# uses Swift 6.2). This script writes the same files that tool would, from
# Package.resolved + nix-prefetch-git (fetchSubmodules=true, matching
# nixpkgs swiftpm2nix.helpers).
#
# Usage (from wwn-containers root, on macOS):
#   scripts/update-apple-container-swiftpm2nix.sh [apple-container-rev]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dependencies/containers/macos/swiftpm2nix"
REV="${1:-0190097d06df0b9065f4c2d2c7873c649d81d493}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching apple/container@$REV Package.resolved"
curl -fsSL "https://raw.githubusercontent.com/apple/container/${REV}/Package.resolved" \
  > "$TMP/Package.resolved"

python3 - "$TMP/Package.resolved" "$TMP/workspace-state.json" "$TMP/pins.tsv" <<'PY'
import json, sys
resolved = json.load(open(sys.argv[1]))
deps = []
pins_path = sys.argv[3]
with open(pins_path, "w") as pins:
    for pin in resolved["pins"]:
        deps.append({
            "basedOn": None,
            "packageRef": {
                "identity": pin["identity"],
                "kind": pin["kind"],
                "location": pin["location"],
                "name": pin["identity"],
            },
            "state": {
                "checkoutState": {
                    "revision": pin["state"]["revision"],
                    "version": pin["state"].get("version", ""),
                },
                "name": "sourceControlCheckout",
            },
            "subpath": pin["identity"],
        })
        pins.write(f"{pin['identity']}\t{pin['location']}\t{pin['state']['revision']}\n")
json.dump({"version": 7, "object": {"dependencies": deps, "artifacts": [], "prebuilts": []}},
          open(sys.argv[2], "w"), indent=2)
print(f"{len(deps)} pins")
PY

echo "prefetching fetchgit hashes (needs nix-prefetch-git)"
mkdir -p "$TMP/hashes"
prefetch_one() {
  local name="$1" url="$2" rev="$3"
  local json hash
  json=$(nix-prefetch-git --url "$url" --rev "$rev" --fetch-submodules --quiet)
  hash=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hash") or d["sha256"])' <<<"$json")
  if [[ "$hash" != sha256-* ]]; then
    hash=$(nix hash to-sri --type sha256 "$hash")
  fi
  printf '%s\n' "$hash" > "$TMP/hashes/$name"
  echo "ok $name $hash"
}
export -f prefetch_one
export TMP
while read -r name url rev; do
  prefetch_one "$name" "$url" "$rev" &
  while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge 6 ]; do
    wait -n || true
  done
done < "$TMP/pins.tsv"
wait

python3 - "$TMP/hashes" "$OUT/default.nix" <<'PY'
import pathlib, sys
hashes_dir = pathlib.Path(sys.argv[1])
pins = {p.name: p.read_text().strip() for p in hashes_dir.iterdir()}
lines = [
    "# Generated from apple/container Package.resolved via swiftpm2nix-style prefetch.",
    "# Regenerate: scripts/update-apple-container-swiftpm2nix.sh",
    "# Stock nixpkgs swiftpm2nix only accepts workspace-state v5–v6; this lock is v7.",
    "{",
    "  workspaceStateFile = ./workspace-state.json;",
    "  hashes = {",
]
for name in sorted(pins):
    lines.append(f'    "{name}" = "{pins[name]}";')
lines += ["  };", "}", ""]
pathlib.Path(sys.argv[2]).write_text("\n".join(lines))
print(f"wrote {sys.argv[2]} ({len(pins)} hashes)")
PY

cp "$TMP/workspace-state.json" "$OUT/workspace-state.json"
echo "updated $OUT — bump fetchFromGitHub rev/hash in apple-container.nix if REV changed"
