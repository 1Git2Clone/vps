# NixOS Image

The image for my self-hosted infrastructure.

## Development

```sh
nix develop
```

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

### Building

```sh
nix build .#default
```

The output is in `result/` (`root` owned image).
