# CI

Two workflows, one per forge. **Forgejo reads `.forgejo/workflows` and falls
back to `.github/workflows` only when that directory is absent** — a fallback,
not a union — so the presence of `.forgejo/workflows/ci.yml` is what keeps
Forgejo off the GitHub file. Delete it and Forgejo silently starts running a
workflow written for GitHub, which is how this repo once ended up with a red
run on git.hu-tao.dev.

| File                           | Runs on                  | Jobs                                         |
| ------------------------------ | ------------------------ | -------------------------------------------- |
| `.forgejo/workflows/ci.yml`    | the dedicated runner box | one: `check`                                 |
| `.forgejo/workflows/pages.yml` | the dedicated runner box | one: `pages` — builds this book, `main` only |
| `.github/workflows/ci.yml`     | the GitHub mirror        | two: `lint` and `evaluate`                   |

| Check    | What                                                                                                                                                              |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| lint     | `pre-commit run --all-files`, then gitleaks across the full history                                                                                               |
| evaluate | evaluates all three `nixosConfigurations`, then `nix flake check --no-build`, then builds `deploy-schema`, `runner-firewall-ordering` and `runner-has-no-secrets` |

**The mirror is push-only.** Commit here and let it flow across; anything
edited on GitHub is overwritten by the next sync, and CI can lag a push until
Forgejo's mirror job runs (_Synchronize Now_ in the repo's mirror settings).

## Why the two files differ

Not tidiness — each difference is forced.

- **Job layout.** The Forgejo file is one job; the mirror's is two. The runner
  keeps a nix store between runs now that it has its own box, but the `.#ci`
  shell still has to be realised, and two jobs would pay that in parallel on
  `capacity: 2`.
- **Actions, or none at all.** The Forgejo job runs on the `nix` label —
  `nixos/nix`, which already contains Nix — so there is no
  `cachix/install-nix-action` to run and no Nix to download per run. That image
  carries **no node**, and every JavaScript action is executed by a node binary
  inside the job container, so the CI file has no `uses:` whatsoever and does
  its own `git fetch` in place of `actions/checkout`.

  `pages.yml` is the exception that proves it. It needs one action —
  `upload-artifact`, which has no shell equivalent — so it puts the dev shell's
  node on `$GITHUB_PATH` first, which is why `nodejs` is in the `ci` shell
  despite nothing here being a node project. Skipping that step fails the job
  with `crun: executable file 'node' not found in $PATH` before the action runs
  at all. `skavex` and `hutao/compress` publish the same way.

  The image is not only a saving, it is the fix: on `ubuntu-latest`
  (`node:22-bookworm`) `install-nix-action` exits 127, because the branch it
  takes without systemd runs `sudo mkdir -p /etc/nix` and that image has no
  sudo. The job is already root, so the sudo bought nothing to begin with.

`permissions:` is a GitHub-only field. Forgejo ignores it with a workflow
warning, which is why the Forgejo file omits it rather than carrying a line
that does nothing.

## Evaluation, not a build

Both forges evaluate rather than build. It catches what actually breaks this
repo — a typo'd option, a missing module argument, an infinite recursion —
without asking a runner to realise a multi-gigabyte closure.

`--no-build` is load-bearing. deploy-rs's `deploy-activate` check references
the system closure, so a plain `nix flake check` builds the whole system, and
since deploy-rs `follows` our nixpkgs its binary is a cache miss and is
compiled from source.

Three checks are built rather than evaluated, and each for a reason:

| Check                      | Why it must build                                                                                                                                                                                                                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `deploy-schema`            | validates `deploy.json` against deploy-rs's schema — the config is otherwise only exercised by a real deploy. `deploy-schema-rejects-bad-input` is its guard: feed the validator a node with no `hostname` and fail if that is accepted, so a validator that silently reads nothing cannot pass forever |
| `runner-firewall-ordering` | greps the evaluated nftables ruleset for rule order. A check that is only evaluated never runs its builder, so its failure branch would be inert                                                                                                                                                        |
| `runner-has-no-secrets`    | same reason — it catches the runner growing a `sops-install-secrets` unit, which a copy-pasted module import would do                                                                                                                                                                                   |

`runner-firewall` — the real two-node VM test with real packets — is **not** in
CI. It needs `/dev/kvm`, and these are shared-vCPU Hetzner instances with no
nested virtualisation; qemu's TCG software emulation was measured at roughly 5×
slower just to boot two minimal nodes. It stays hand-run on a machine with KVM:

```sh
nix build .#checks.x86_64-linux.runner-firewall -L
```

## Writing a workflow that runs here

The runner is a different machine from the VPS, with no access to its volumes
and a four-path allow-list to its Forgejo instance. Three consequences:

1. **`upload-artifact` must be the Forgejo fork.** GitHub's bundles
   `@actions/artifact` v2, which decides a Forgejo instance is GitHub
   Enterprise Server and **throws before opening a socket** — zero HTTP
   requests, invisible in access logs. Use `forgejo/upload-artifact@v5`; a bare
   `uses:` resolves against `https://code.forgejo.org`, which is correct for
   it.
2. **Publishing writes an artifact, never a volume.** See [Pages](pages.md).
3. **A bare `uses:` resolves against `DEFAULT_ACTIONS_URL`** — which defaults
   to `https://data.forgejo.org`, a mirror of `actions/*` and nothing
   third-party. A third-party action must name its host, or it fails with
   `remote: Not found`. Pointing `DEFAULT_ACTIONS_URL` at github.com would fix
   it instance-wide, at the cost of making every bare `uses:` resolve to
   whoever holds that name on an open-registration forge.

Caching works normally — see
[why the cache works when artifacts did not](../architecture/runner.md#why-the-cache-works-when-artifacts-did-not).
`No cache found.` is the successful-but-empty branch, not a broken cache.

## Known gaps

- Actions are pinned by **moving tag** rather than commit SHA.
- The artifact pull has no size cap (`--max-time` bounds time, not bytes).
- Job containers do not yet use `--userns=auto`.
