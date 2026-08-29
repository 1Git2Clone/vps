#!/usr/bin/env bash
# Populates the extra-files tree nixos-anywhere copies onto the target before
# the first boot. The current directory becomes / on the target.
#
# The key must be the private half of one of the recipients in .sops.yaml, or
# sops-install-secrets fails during activation and the machine has no
# credentials for anything — including its own login.
set -euo pipefail

key="${SOPS_AGE_KEY_FILE:-$HOME/.sops-nix/key.txt}"

if [ ! -f "$key" ]; then
	echo "no age key at $key — set SOPS_AGE_KEY_FILE" >&2
	exit 1
fi

install -d -m 0755 var/lib/sops-nix
install -m 0600 "$key" var/lib/sops-nix/key.txt
