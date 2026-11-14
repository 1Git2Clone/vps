#!/usr/bin/env bash
set -euo pipefail

seeder=$1
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
seeds="$work/seeds"
installed="$work/installed"
mkdir -p "$seeds/Extension-Test" "$installed/Installed-From-UI"
printf 'pin-1\n' > "$seeds/Extension-Test/.nix-src"
printf 'original code\n' > "$seeds/Extension-Test/index.js"
printf 'keep me\n' > "$installed/Installed-From-UI/state"
chmod -R a-w "$seeds"

# Store permissions must not make the installed extension read-only.
bash "$seeder" "$seeds" "$installed"
test -w "$installed/Extension-Test/index.js"
printf 'extension state\n' > "$installed/Extension-Test/state"
printf 'runtime edit\n' > "$installed/Extension-Test/index.js"

# Reboot/no-op deploy preserves both extension-created state and code edits.
bash "$seeder" "$seeds" "$installed"
test "$(cat "$installed/Extension-Test/state")" = 'extension state'
test "$(cat "$installed/Extension-Test/index.js")" = 'runtime edit'

# A changed pin replaces only the managed extension, including local state.
chmod -R u+w "$seeds"
printf 'pin-2\n' > "$seeds/Extension-Test/.nix-src"
printf 'new code\n' > "$seeds/Extension-Test/index.js"
chmod -R a-w "$seeds"
bash "$seeder" "$seeds" "$installed"
test "$(cat "$installed/Extension-Test/.nix-src")" = pin-2
test "$(cat "$installed/Extension-Test/index.js")" = 'new code'
test ! -e "$installed/Extension-Test/state"
test "$(cat "$installed/Installed-From-UI/state")" = 'keep me'

# An unmanaged extension with a conflicting name must never be overwritten.
rm "$installed/Extension-Test/.nix-src"
printf 'user-installed code\n' > "$installed/Extension-Test/index.js"
if bash "$seeder" "$seeds" "$installed"; then
  echo 'Seeder unexpectedly overwrote an unmanaged extension' >&2
  exit 1
fi
test "$(cat "$installed/Extension-Test/index.js")" = 'user-installed code'

# No temporary installation directories may be left behind.
test -z "$(find "$installed" -maxdepth 1 -name '.nix-seed.*' -print -quit)"
