# NixOS Image

The image for my self-hosted infrastructure.

## Development

```sh
nix develop
```

Or

```sh
nix develop -c zsh
```

If you're on zshell.

### Configuration

Set your `config.yaml` using SOPS + age

```sh
mkdir -p ~/.sops-nix
age-keygen | tee ~/.sops-nix/key.txt > /dev/null
chmod 0600 ~/.sops-nix/key.txt
```

Then edit it

```sh
SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt nix develop -c sops secrets.yaml
```

### Running

Tests can be ran with:

```sh
nix run github:nix-community/nixos-anywhere -- --flake .#vps --vm-test
```

The actual system (infinitely more useful):

```sh
QEMU_OPTS="-vnc :0" nix run .#default
```

And ssh into it from another terminal (`ssh -p 2222 root@127.0.0.1`) (there's
no place like `127.0.0.1`).
