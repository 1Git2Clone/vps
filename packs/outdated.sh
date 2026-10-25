#!/usr/bin/env bash
# Fails when a mod in any pack has a newer build for the pack's own Minecraft
# version. Runs `packwiz update --all` on a throwaway copy of each pack, so the
# tree is never touched, and compares Modrinth version ids rather than whole
# files: an update can also reset a hand-set `side`, which is not a new
# version. Not filenames either: some mods ship every build under one name.
#
# Exceptions are packwiz's own: `packwiz pin <mod>` writes `pin = true` into
# that mod's .pw.toml and update skips it; `packwiz unpin <mod>` undoes it.
# Run by .forgejo/workflows/mods.yml on a schedule, or by hand.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

outdated=0
for pack in */pack.toml; do
  name=$(dirname "$pack")
  cp -r "$name" "$work/$name"
  (cd "$work/$name" && packwiz update --all --yes >/dev/null)
  while IFS= read -r file; do
    if [ "$(grep '^version = ' "$name/$file")" != "$(grep '^version = ' "$work/$name/$file")" ]; then
      side=$(grep -m1 '^side = ' "$name/$file" | cut -d'"' -f2)
      old=$(grep -m1 '^filename = ' "$name/$file" | cut -d'"' -f2)
      new=$(grep -m1 '^filename = ' "$work/$name/$file" | cut -d'"' -f2)
      printf '%s  %-7s %s -> %s\n' "$name" "$side" "$old" "$new"
      outdated=$((outdated + 1))
    fi
  done < <(cd "$name" && find . -name '*.pw.toml' | sed 's|^\./||' | LC_ALL=C sort)
done

if [ "$outdated" -gt 0 ]; then
  echo "$outdated mod(s) have a newer build: update with packwiz update, or packwiz pin to hold one back" >&2
  exit 1
fi
echo "every unpinned mod is on its newest build"
