#!/usr/bin/env bash
# Regenerate the swiftpm2nix-style lock for wwn-containerd (Package.resolved).
#
# Usage (from wwn-containers root, on macOS with nix):
#   scripts/update-wwn-containerd-swiftpm2nix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$ROOT/dependencies/containers/macos"
OUT="$MACOS/wwn-containerd-swiftpm2nix"
RESOLVED="$MACOS/Package.resolved"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$RESOLVED" ]] || { echo "missing $RESOLVED" >&2; exit 1; }

python3 - "$RESOLVED" "$TMP/workspace-state.json" "$TMP/pins.tsv" <<'PY'
import json, sys
resolved = json.load(open(sys.argv[1]))
deps = []
with open(sys.argv[3], "w") as pins:
    for pin in resolved["pins"]:
        state = pin["state"]
        rev = state.get("revision") or state.get("branch", "main")
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
                    "revision": rev,
                    "version": state.get("version", ""),
                },
                "name": "sourceControlCheckout",
            },
            "subpath": pin["identity"],
        })
        pins.write(f"{pin['identity']}\t{pin['location']}\t{rev}\n")
json.dump({"version": 7, "object": {"dependencies": deps, "artifacts": [], "prebuilts": []}},
          open(sys.argv[2], "w"), indent=2)
print(f"{len(deps)} pins")
PY

echo "prefetching fetchgit hashes"
mkdir -p "$TMP/hashes"
while read -r name url rev; do
  json=$(nix-prefetch-git --url "$url" --rev "$rev" --fetch-submodules --quiet)
  hash=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hash") or d["sha256"])' <<<"$json")
  if [[ "$hash" != sha256-* ]]; then
    hash=$(nix hash to-sri --type sha256 "$hash")
  fi
  printf '%s\n' "$hash" > "$TMP/hashes/$name"
  echo "ok $name"
done < "$TMP/pins.tsv"

python3 - "$TMP/hashes" "$OUT/default.nix" <<'PY'
import pathlib, sys
hashes_dir = pathlib.Path(sys.argv[1])
pins = {p.name: p.read_text().strip() for p in hashes_dir.iterdir()}
lines = [
    "# Generated from dependencies/containers/macos/Package.resolved.",
    "# Regenerate: scripts/update-wwn-containerd-swiftpm2nix.sh",
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
echo "updated $OUT"
