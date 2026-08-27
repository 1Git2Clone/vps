# NixOS Image

The image for my self-hosted infrastructure.

## Development

```sh
nix develop
```

Then do whatever edits you want...

To test it out do

```sh
nix build .#default
```

The output is in `result/` (`root` owned image).
