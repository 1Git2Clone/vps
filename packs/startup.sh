#!/usr/bin/env bash
set -euo pipefail

builds=${1:?Usage: packs/startup.sh BUILD_OUTPUT_DIRECTORY [WORLD ...]}
shift
if [ "$#" -eq 0 ]; then
  set -- mc1 mc2 mc3 mc4
fi

for world in "$@"; do
  case "$world" in
    mc1|mc2|mc3|mc4) ;;
    *) printf 'Unknown world: %s\n' "$world" >&2; exit 2 ;;
  esac
  printf '\n=== Booting %s ===\n' "$world"
  python3 -I packs/startup.py "$builds/$world" "$builds/$world-server-mods"
done
