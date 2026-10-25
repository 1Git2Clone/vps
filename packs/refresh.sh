#!/usr/bin/env bash
# packwiz refresh in every pack: rewrites each index.toml, packwiz's hash of
# every file in that pack. Run by the packwiz-refresh pre-commit hook; when it
# changes an index, the commit stops for a re-stage like any other fixer.
set -euo pipefail
cd "$(dirname "$0")"
for pack in */pack.toml; do
  (cd "$(dirname "$pack")" && packwiz refresh)
done
