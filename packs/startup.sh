#!/usr/bin/env bash
set -euo pipefail

for world in mc1 mc2 mc3 mc4; do
  printf '\n=== Booting %s ===\n' "$world"
  pack=$(nix build --no-link --print-out-paths ".#${world}-mrpack")
  mods=$(nix build --no-link --print-out-paths ".#${world}-server-mods")
  python3 -I packs/startup.py "$pack" "$mods"
done
