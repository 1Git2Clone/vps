#!/usr/bin/env bash
# Refresh only Nix-managed extensions whose source pin changed. The caller
# stops SillyTavern first and runs as the same uid that owns its volume files.
set -euo pipefail

seed_root=$1
extension_root=$2
stage=""
trap 'if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi' EXIT

for source in "$seed_root"/*; do
  name=$(basename "$source")
  dest="$extension_root/$name"

  if cmp -s "$source/.nix-src" "$dest/.nix-src"; then
    continue
  fi

  # Never silently replace a folder installed through the UI.
  if [[ -e "$dest" || -L "$dest" ]] && [[ ! -f "$dest/.nix-src" ]]; then
    echo "Refusing to replace unmanaged SillyTavern extension: $name" >&2
    exit 1
  fi

  # Prepare the complete writable copy before touching the existing directory.
  stage=$(mktemp -d "$extension_root/.nix-seed.XXXXXX")
  cp -R --no-preserve=mode,ownership "$source/." "$stage/"
  chmod -R u+rwX "$stage"
  rm -rf -- "$dest"
  mv -T -- "$stage" "$dest"
  stage=""
done
