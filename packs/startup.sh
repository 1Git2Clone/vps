#!/usr/bin/env bash
set -euo pipefail

builds=${1:?Usage: packs/startup.sh BUILD_OUTPUT_DIRECTORY}

for world in mc1 mc2 mc3 mc4; do
  printf '\n=== Booting %s ===\n' "$world"
  python3 -I packs/startup.py "$builds/$world" "$builds/$world-server-mods"
done
