# Development

```sh
nix develop            # or `nix develop -c zsh`
```

The shell carries everything: nixfmt, statix, sops, age, nixos-anywhere,
nixos-rebuild, opentofu, deploy-rs, pre-commit, gitleaks, markdownlint-cli2 and
mdbook. `.#ci` is a deliberately smaller subset — see [CI](ci.md).

## Running it locally

Tests:

```sh
nix run github:nix-community/nixos-anywhere -- --flake .#vps --vm-test
```

The actual system (infinitely more useful):

```sh
QEMU_OPTS="-vnc :0" nix run .#default
```

And ssh into it from another terminal — `ssh -p 2222 hutao@127.0.0.1` (there's
no place like `127.0.0.1`). Port 2222 on both ends, because sshd moved off 22 so
forgejo could publish it.

The VM disk is 32G (`virtualisation.vmVariantWithDisko`). The disko default of 2G
leaves ~987M for `/` once the ESP takes its gigabyte, which cannot hold the eleven
declared images — the VM fills up mid-boot and every service that needs disk fails
in a way that reads like a bug in that service. This applies to `nix run .` only;
the Hetzner disk is sized by the provider.

## Working from a Mac

The devShell is built for all four mainstream systems — `x86_64-linux`,
`aarch64-linux`, `aarch64-darwin`, `x86_64-darwin`. Every tool in it,
`nixos-anywhere`, `nixos-rebuild` and `deploy-rs` included, exists on each.
Secrets, formatting, `statix` and the hooks work unchanged.

What does _not_ carry over is building the system closure. The outputs that
describe the box — `nixosConfigurations`, `packages`, `apps` — are
`x86_64-linux` only, so `nix build .`, `nix run .` (the QEMU VM) and
`nix run .#install` fail on anything else: a Mac has no Linux builder at all,
and an `aarch64-linux` workstation is the wrong architecture. Deploys work, but
only if the build happens somewhere else:

```sh
deploy -s --remote-build .#vps         # build on the VPS itself
nixos-rebuild switch --flake .#vps-hetzner \
  --target-host hutao@vps --build-host hutao@vps --use-remote-sudo
```

`-s` is not optional here. deploy-rs runs `nix flake check` first, and every
check in this flake reaches `nixosConfigurations.*.system.build.toplevel`, so
the check itself is an `x86_64-linux` build:

```text
error: build of '…-10-acme.conf.drv^*' failed: platform mismatch
       Required system: 'x86_64-linux'   Current system: 'aarch64-darwin'
```

There is nothing to keep by skipping selectively — `checks.aarch64-darwin`
exists but both entries depend on the same Linux closure, so none of them
build here either.

`--remote-build` then evaluates locally (which darwin does fine), copies the
`.drv` with `nix copy --to ssh-ng://hutao@vps --derivation`, and realises it on
the box. That copy needs the ssh user to be a trusted nix user; `hutao` is in
`wheel` and `modules/nix.nix` trusts `@wheel`, so it already is.

The alternative is a Linux remote builder in `/etc/nix/machines` (or
`nix-darwin`'s `nix.linux-builder`), after which the plain commands above work
as written — including `nix run .#install`, which is otherwise Linux-only and so
still the reason a first install is done from a Linux machine.

## Formatting

Formatting is **nixfmt**, not nixpkgs-fmt — every `.nix` file here conforms to
it and the two disagree on multi-argument lambdas, so the wrong one reformats the
whole tree.

```sh
nixfmt $(git ls-files '*.nix') && statix check .
tofu -chdir=tofu fmt -recursive && tofu -chdir=tofu validate
```

## Hooks

```sh
nix develop -c pre-commit install         # once per clone
nix develop -c pre-commit run --all-files
```

`.pre-commit-config.yaml` is the single definition — the local commit hook and CI
run the same file, so a check cannot pass here and fail there. It covers nixfmt,
statix, `tofu fmt`, **markdownlint-cli2**, the usual whitespace/YAML/merge-conflict
hooks, and **gitleaks** over the staged diff.

See [below](#markdown-is-linted-not-formatted-by-the-hook) for what the
markdown hook does and does not do.

gitleaks scans the staged diff rather than the working directory on purpose:
`gitleaks dir` reads gitignored files, and `tofu/terraform.tfvars` legitimately
holds live tokens — scanning it would fail the hook forever over a file git will
never accept. History scanning is a CI step instead.

## Writing documentation

This book is `docs/`. `mdbook` and `mdbook-mermaid` are in the dev shell:

```sh
nix run .#docs                             # install assets, then serve
nix develop -c mdbook build docs           # what CI does
```

`nix run .#docs` exists because the build has a prerequisite that is easy to
forget: `mdbook-mermaid install docs` writes `mermaid.min.js` and
`mermaid-init.js` next to `book.toml`, and `book.toml` references them. Those
two files are **gitignored** — 2.6 MB of vendored minified JS whose version is
already pinned by `flake.lock` — so a fresh clone does not have them and
`mdbook build` fails until they are written. The app does both steps; the
workflow does the same two commands explicitly.

`create-missing = false` in `book.toml`, so a link to a page that does not
exist fails the build rather than publishing a 404.

### Diagrams are mermaid, and that is the point

Every diagram here is a ` ```mermaid ` fence in the markdown. Forgejo bundles
mermaid 11.16.1, so the same source renders in **three** places with no build
step: this book, the Forgejo web UI when browsing `docs/src/`, and a pull
request that changes one.

That is the whole reason they are not SVGs, D2, or the ASCII art they replaced.
A picture that only exists after a build is a picture nobody sees while
reviewing the change that invalidates it.

### Markdown is linted, not formatted, by the hook

`markdownlint-cli2` reports a code fence with no language and a paragraph past
80 columns. It rewrites nothing.

Formatting is prettier's, run by an editor on save rather than by a hook, and
`.markdownlint-cli2.yaml` is tuned so prettier's output passes untouched. The
config lists every rule that is off and why. Prettier is deliberately not in
the dev shell: nixpkgs-26.05 carries 3.8.3, which mangles a paragraph
containing both an intraword underscore and an emphasis span.

`docs/superpowers/` is not linted — those are agent-generated plan and spec
records, kept as history.
