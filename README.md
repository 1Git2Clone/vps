# NixOS Image

The image for my self-hosted infrastructure: one flake that describes the whole
VPS — disks, firewall, secrets, every container service — plus the OpenTofu that
creates the machine and publishes its DNS.

Ported from the Ansible repo it replaces. What that repo needed three layers for
(docker's restart policy, a boot-time `docker-services.sh` sweep, and an Ansible
converge run from a workstation) is one layer here: systemd units built from this
flake. There is no state on the server that this repo does not describe, and
nothing to remember to run.

```
.
├── configuration.nix     # the import list, nothing else
├── disk-config.nix       # disko layout + the local QEMU VM
├── flake.nix             # nixosConfigurations.vps and .vps-hetzner
├── .pre-commit-config.yaml  # the checks, shared by the commit hook and CI
├── .github/workflows/    # CI, run on the GitHub mirror
├── modules/
│   ├── options.nix       # infra.* — domain, tailnet IP, proxy network
│   ├── secrets.nix       # every sops key, declared
│   ├── acme.nix          # one certificate, DNS-01 via Cloudflare
│   ├── firewall.nix      # nftables, including the container forward path
│   ├── services.nix      # sshd, tailscale, fail2ban, docker
│   ├── security.nix      # auditd rules
│   ├── postgres.nix      # host postgres + pgbouncer, pg_dumpall backups
│   ├── backups.nix       # restic → B2, daily + weekly quiescent minecraft
│   ├── vuln-scan.nix     # weekly CVE report, every image + the system closure
│   ├── syncthing.nix     # tailnet-only, /home/hutao/syncthing
│   ├── boot.nix hardware.nix networking.nix nix.nix users.nix
│   └── containers/       # one module per service
└── tofu/                 # hcloud server + edge firewall, Cloudflare DNS
```

## Services

| Service | Exposure |
|---|---|
| `caddy` | 80/443 (+443/udp) for the public sites, and 8880/8443 for the tailnet-only ones — the second pair is kept private by its absence from the firewall's allow-lists, and nftables rewrites tailscale0's 80/443 onto it so those URLs carry no port. Built locally with the `caddy-ratelimit` module (`caddy.withPlugins`), not the stock image |
| `cloudflared` | Tunnel connected, but **nothing routes through it** — `git`/`music`/`mail`/`smtp` are unproxied A records straight to the VPS, so caddy serves them directly |
| `mailserver` | SMTP/IMAP direct on 25, 465, 587, 993 — an MX must reach the host |
| `webmail` | roundcube, proxied at `mail.` |
| `forgejo` | **SSH on 22**, so clone URLs need no port; HTTP via caddy at `git.` |
| `forgejo-runner` | **nothing published**; polls forgejo for Actions jobs and asks the host's docker for a container per job |
| `navidrome` | `127.0.0.1:4533`, reached only through caddy at `music.` |
| `kuma` | proxy network only, reached at `status.` |
| `searxng` | proxy network only, reached at `search.`; the only public site behind `basic_auth`, with caddy `rate_limit` in front of the bcrypt |
| `dozzle` | `dozzle.` over the tailnet, and still 8080 directly — the direct port is deliberate, since this is what you open when caddy is the broken part |
| `grafana` | host networking, :3000, tailnet only; also `grafana.`, which caddy reaches at the docker bridge address because host networking is invisible to docker's DNS |
| `tempo` | host networking, OTLP 4317/4318 bound to `0.0.0.0`; kept private by the firewall's input chain, not by the bind address |
| `minecraft` | 25565; RCON on loopback only (25575) |
| `minecraft2` | second world, MC **1.21.1** on the `java21` image (world 1 is 26.1.2/java25) with its own mod list; 25566, reached via the `_minecraft._tcp.mc2` SRV record; RCON on loopback only (25576) |
| `serenity-bot-0` | **nothing published**; an outbound Discord gateway client, on the `botnet` network. tokio-console on `127.0.0.1:6669` |
| `serenity-redis` | `botnet` only, no published port, no volume — a cache with a Discord fallback |
| `postgres` | not a container — a host service; unix socket + loopback only, never on `botnet` |
| `pgbouncer` | not a container — a host service; 6432, reachable from `botnet` and the tailnet, kept private by the firewall's input chain |
| `syncthing` | not a container — a host service; GUI on 8384, tailnet only; also `syncthing.`, where caddy must rewrite the `Host` header or syncthing's rebinding check answers 403 |

Forgejo owns port 22, so **the host's sshd is on 2222** and normal access is over
Tailscale SSH. Keeping 22 is what lets git remotes stay portless: ssh has no
service discovery — it reads no `SRV` record — so anything else has to be spelled
out in every clone URL or every client's `~/.ssh/config`.

## The things that will bite you

Six, all of them load-bearing, all of them silent when wrong.

**A published container port lives in the forward chain, not input.** It is
DNAT'd in prerouting and then forwarded, so it never touches the input hook.
Docker writes its own accepts into the `ip filter` table, and in nftables every
table's chain runs — an accept over there cannot rescue a packet `table inet
nixos-fw` drops. So a policy-drop forward chain with no rules leaves every
container unreachable *and* without egress. When adding a service, its port goes
in the forward allow-list; getting that backwards gives you a port the internet
can reach that the firewall never authorised.

**fail2ban's `chain = DOCKER-USER` does not translate.** That is the right answer
for iptables. With `networking.nftables` on, NixOS resolves
`banaction-allports` to `nftables-allports`, where `chain` is only the nftables
*chain name* — so `DOCKER-USER` would name an input-hooked chain and ban nothing
that reaches a container. `chain_hook = forward` is the part that moves it. See
the `forgejo-ssh` jail in `modules/services.nix`, and check the live result with
`nft list table inet f2b-table`.

**The forgejo container needs `--log-opt tag=forgejo`.** The jail reads the
journal, and without the tag the journal identifier is the container ID, which
changes on every recreate. The jail then looks perfectly healthy and matches
nothing.

**A bind-mounted sops secret goes stale.** A rendered secret's real path is under
a generation directory and `path` only symlinks to it; docker resolves the
symlink at mount time and holds that inode forever. `dozzle-users.service` and
`mailserver-dkim.service` copy to a stable path first, which is why they exist.

**A sops env file changes without restarting anything.** `sops.templates.<n>.path`
is a stable path, so rotating a value changes the file's *content* and nothing
else — the unit text is byte-identical and `switch-to-configuration` finds no
unit to restart. The container keeps the old value in its environment until
something unrelated recreates it, which can be weeks. `restartUnits` on the
template is the fix: sops-nix diffs the rendered file and restarts only on a
real change, so no-op deploys still don't bounce the service. `navidrome.env`
does this; the older env templates predate it.

**The two firewalls must both allow a port.** `tofu/modules/hetzner-firewall` is
the edge and `modules/firewall.nix` is the host. Each is what survives a
misconfiguration of the other, so when something is unreachable, check both.

## What changed in the port

Not a 1:1 translation. The deliberate departures:

- **Data lives in named docker volumes**, never a bind-mounted host directory.
  `services.restic` backs up `/var/lib/docker/volumes` wholesale, so a service
  added later is covered the moment it declares a volume. A backup that has to
  be told about each new service is a backup that eventually stops covering one.
  The Ansible roles' data guards (`assert` that `data/world` exists before
  provisioning) have no equivalent and need none — there is no path to point at
  the wrong place.

- **Configuration comes from the Nix store**, read-only. Store files are 0444,
  which is what the tempo (uid 10001) and grafana (uid 472) permission failures
  in the Ansible setup were about; and a store path changes when its content
  does, so systemd recreates the container on a config-only change. That is what
  `recreate: always` was working around.

- **Certificates are `security.acme`**, not a certbot container plus cron. The
  certificate is *named* `hu-tao.dev` with the subdomains as SANs, so reordering
  the list cannot silently issue a second lineage the way certbot's
  name-after-the-first-`-d` behaviour could. Note NixOS calls the key
  `key.pem`, not certbot's `privkey.pem`, and DMS reads it with
  `SSL_TYPE=manual` rather than guessing from `$SSL_DOMAIN`.

- **Images pin a release tag and no digest.** The Ansible repo pinned
  `tag@sha256:…`; the digests have since gone stale, and a release tag has been
  the more stable of the two in practice. `:latest` is still never used — for
  tempo it is a main-branch build that reports a version which was never
  released.

- **Real credentials everywhere.** Grafana's anonymous-Admin access is off and
  the login comes from sops, as do dozzle's bcrypt hash and minecraft's RCON
  password. **uptime-kuma is the exception, unavoidably**: it has no environment
  variable or config file that seeds an admin account — the first visitor is
  prompted to create one and the route then closes. Create it immediately after
  the first deploy. **searxng is the other exception, for the opposite reason**:
  it has no concept of a user at all, so there is nothing to seed — caddy's
  `basic_auth` is the entire access control and the hash lives in sops. Because
  `basic_auth` runs a cost-14 bcrypt on every request, caddy's `rate_limit`
  (a compiled-in module) sits in front of it and returns 429 before the hash
  runs, so a password flood cannot become CPU exhaustion. It is in-process on
  purpose — see the fail2ban row in [ARCHITECTURE.md](ARCHITECTURE.md#12-failure-modes-and-recovery)
  for the forward-chain ban whose blast radius it avoids.

  Generate that hash with `mkpasswd`, which is already on the host:

  ```sh
  mkpasswd -m bcrypt -R 14
  ```

  **`-R 14` is not optional.** mkpasswd defaults to cost 05 and caddy's own
  `hash-password` uses 14, so the default silently produces a hash 512x cheaper
  to attack than the one caddy would have made. The `$2b$` prefix mkpasswd emits
  is fine — caddy verifies through golang.org/x/crypto/bcrypt, which records the
  minor version without validating it, so `$2a$`, `$2b$` and `$2y$` are
  interchangeable.

- **Not ported: `camofox` and `serenity-bot`.** They are host systemd units for
  an npm project and a Rust binary checked out under `/home`, not container
  services, and they depend on trees this image does not create.

## Configuration

Set your secrets using SOPS + age.

```sh
mkdir -p ~/.sops-nix
age-keygen | tee ~/.sops-nix/key.txt > /dev/null
chmod 0600 ~/.sops-nix/key.txt
```

Then edit them:

```sh
SOPS_AGE_KEY_FILE=~/.sops-nix/key.txt nix develop -c sops secrets.yaml
```

`secrets.example.yaml` is the template. **Every key declared in
`modules/secrets.nix` must exist**, or `sops-install-secrets` fails during
activation — which on a fresh install means the machine boots with no
credentials at all, its own login included.

Beyond what the Ansible vault held, this port needs:

| Key | Why |
|---|---|
| `forgejo/runner_token` | one-time Actions runner registration token; the runner trades it for its own secret on first start |
| `grafana/admin_user`, `grafana/admin_password` | anonymous Admin is off, so this is the only way in |
| `kuma/healthcheck_url` | the out-of-band status-page probe; a separate check from the backup one because they fail for different reasons |
| `minecraft/rcon_password` | RCON is loopback-only but it is still a remote console |
| `minecraft2/rcon_password` | the second world's console. A separate password on purpose — one leak should not reach both worlds |
| `serenity/bot_token`, `serenity/ai_api_key` | the Discord bot's gateway token and its DeepSeek key |
| `searxng/secret_key` | signs searxng's session cookies; upstream's default is the literal `ultrasecretkey` |
| `searxng/admin_user`, `searxng/admin_password_hash` | searxng has no accounts, so caddy's `basic_auth` is the whole access control. bcrypt, same shape as dozzle's |
| `serenity/db_password` | one password, two consumers: `ALTER ROLE` in postgres and the pgbouncer userlist, both rendered from this key |
| `navidrome/lastfm/api_key`, `navidrome/lastfm/secret` | one Last.fm application registration, reaching the container as `ND_LASTFM_APIKEY` / `ND_LASTFM_SECRET`. Enables scrobbling server-side; each user still links their own account under Personal Settings |

`acme_email` is **gone** from the secret set: `security.acme` needs it at
evaluation time and a registration contact is not a credential. It is
`infra.acmeEmail` in `modules/options.nix`.

## Actions and Pages

`FORGEJO__actions__ENABLED` was true from the start and nothing ran the jobs.
`modules/containers/forgejo-runner.nix` is the runner half, and
`pages.<domain>` is a static site caddy serves out of one docker volume that
workflows write into.

The URL layout is the directory layout, with no rewriting anywhere:

```
/srv/pages/<owner>/<repo>/index.html   →   https://pages.hu-tao.dev/<owner>/<repo>/
```

A repo publishes by mounting that volume in its job and writing into
`$GITHUB_REPOSITORY`, which is already `<owner>/<repo>`:

```yaml
jobs:
  pages:
    runs-on: ubuntu-latest
    container:
      image: node:22-bookworm
      volumes:
        - pages_data:/pages
    steps:
      - uses: actions/checkout@v4
      - run: |
          dest="/pages/$GITHUB_REPOSITORY"
          rm -rf "$dest" && mkdir -p "$dest"
          cp public/index.html "$dest/"
```

**The runner mounts the host's docker socket**, which is root on this box. What
makes that acceptable is written out at the top of the module: registration is
disabled on the instance, `container.valid_volumes` is an allow-list holding
only `pages_data`, and job containers are unprivileged. The socket is there
rather than a docker-in-docker sidecar because dind has its own storage — a
job inside it could not write a volume caddy can read.

Two manual steps, both once:

1. **Create the runner record** and copy its two values: Site Administration →
   Actions → Runners → **Create new runner**. The uuid goes in
   `modules/containers/forgejo-runner.nix` as `runnerUuid`, the secret goes in
   `forgejo/runner_token`:

   ```sh
   nix develop -c sops secrets.yaml     # forgejo: runner_token: <token>
   ```

   Do this **before** the deploy: `sops-install-secrets` validates the manifest
   at *build* time, so a missing key fails `nix build`, not just activation.

2. **Point `pages.<domain>` at the box** — an unproxied A record to the same
   address as `git.`, like the other seven.

   The A records come from `var.subdomains` in
   `tofu/modules/cloudflare-dns/variables.tf`, which drives
   `cloudflare_dns_record.a`. `pages` is in that list, so the record is tofu's.

   A correct plan for it reads **1 to add, 1 to change, 0 to destroy**, and the
   change is `hcloud_server.vps` in place, setting `ignore_remote_firewall_ids`,
   `keep_disk` and `shutdown_before_deletion` — all three absent from state
   because the importer never wrote them, none of them an API call against the
   running machine. What makes the plan wrong is a `public_net` block appearing
   anywhere in it: that is the diff that detached 167.233.24.58 on 2026-09-05.
   See the lifecycle comment in `tofu/server.tf`.

   The certificate does not wait for the record: `pages` is in
   `infra.certSubdomains` and the challenge is DNS-01, so the SAN is issued
   whether or not the name resolves.

After the deploy, the runner appears under Site Administration → Actions →
Runners — which is the whole check, and it needs no shell on the box either.

The identity is declared, so there is no registration step and no `.runner`
state file. A wrong uuid or secret shows up as an authentication error in
`journalctl -u docker-forgejo-runner` and nowhere else — it cannot fail a
deploy. If a `.runner` file survives from an older, registered setup, the
daemon refuses to start at all: "server connection conflict … only one config
file can provide server connections". Empty `forgejo_runner_data` in that
case.

If the runner comes up and no job ever starts, the usual cause is the job
image failing to pull, which shows in the same journal.

## Deploying

Two ways, and the second exists because the first is a third-party dependency.

### 1. deploy-rs — the normal path

```sh
nix develop            # or: nix run github:serokell/deploy-rs -- .#vps
deploy .#vps
```

Builds locally, pushes the closure over ssh, activates, then **reconnects on a
fresh connection to confirm the box is still reachable**. If it cannot, the
machine rolls itself back to the previous generation unattended. That is the
whole reason it is here: it is the only thing that saves you from a firewall or
sshd change that locks you out, which is a failure you otherwise fix from the
provider's console.

It runs as root on the target (via `security.sudo.wheelNeedsPassword = false`),
and is pinned by revision in `flake.lock`, so upstream changing does not change
what you run — only `nix flake update` does.

### 2. nixos-rebuild — no extra dependency, no rollback

```sh
nix develop            # nixos-rebuild is in the devShell
nixos-rebuild switch --flake .#vps-hetzner \
  --target-host hutao@vps --use-remote-sudo
```

`nixos-rebuild` ships with NixOS and is therefore absent on a non-NixOS
workstation, which is why the devShell provides it. Outside the shell, use
`nix run nixpkgs#nixos-rebuild -- switch ...`.

Identical build, push and activation — NixOS calls the same
`switch-to-configuration`. What you lose is the confirmation step. Break sshd,
nftables or networking and nothing rolls back; you recover from the Hetzner
console, or by picking the previous generation in the GRUB menu at boot.

Worth using deliberately when you *want* no supervision — e.g. deploying from
the box itself.

### If deploy-rs ever disappears from GitHub

The risk is bigger than losing `deploy`: flake inputs are fetched from source,
not from the binary cache, so an unresolvable input means **the flake stops
evaluating entirely** and `nixos-rebuild --flake` fails too.

Three mitigations, in order of effort:

1. **Nothing breaks while the store path is present.** A locked input already
   realised in `/nix/store` is not refetched. `nix flake archive` copies every
   input into the store on purpose, and `nix-store --gc` is what would remove
   them again.
2. **Keep a copy**: `nix flake archive --to file:///path/to/mirror` writes all
   inputs somewhere you control.
3. **Cut it out** — a three-part edit to `flake.nix`, after which option 2 above
   is the only deploy path:
   - delete the `deploy-rs` entry from `inputs`
   - delete `deploy-rs` from the `outputs = { ... }` argument list
   - delete the `deploy` and `checks` outputs, and `deploy-rs.packages.${system}.default`
     from the devShell

   Nothing in `modules/` references it, so the machine configuration itself is
   unaffected.

## Documentation

| Doc | For |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the box fits together and why: trust boundaries, the two firewalls, TLS/DNS/mail chain, data flow, the deploy and state model, and the failure modes that shaped it |
| [docs/deploying.md](docs/deploying.md) | The three paths: redeploy, first deploy, bare metal — and the settings that make a bare-metal install actually automatic |
| [docs/migration.md](docs/migration.md) | Moving this stack from the old Ubuntu/Ansible box: data mapping, ordering, the primary-IP cutover, rollback |

## Development

```sh
nix develop
```

Or `nix develop -c zsh` if you're on zshell.

### From a Mac

The devShell is built for all four mainstream systems — `x86_64-linux`,
`aarch64-linux`, `aarch64-darwin`, `x86_64-darwin`. Every tool in it,
`nixos-anywhere`, `nixos-rebuild` and `deploy-rs` included, exists on each.
Secrets, formatting, `statix` and the hooks work unchanged.

What does *not* carry over is building the system closure. The outputs that
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

```
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

Formatting is **nixfmt**, not nixpkgs-fmt — every `.nix` file here conforms to
it and the two disagree on multi-argument lambdas, so the wrong one reformats the
whole tree.

```sh
nixfmt $(git ls-files '*.nix') && statix check .
tofu -chdir=tofu fmt -recursive && tofu -chdir=tofu validate
```

### Hooks

```sh
nix develop -c pre-commit install         # once per clone
nix develop -c pre-commit run --all-files
```

`.pre-commit-config.yaml` is the single definition — the local commit hook and CI
run the same file, so a check cannot pass here and fail there. It covers nixfmt,
statix, `tofu fmt`, the usual whitespace/YAML/merge-conflict hooks, and
**gitleaks** over the staged diff.

gitleaks scans the staged diff rather than the working directory on purpose:
`gitleaks dir` reads gitignored files, and `tofu/terraform.tfvars` legitimately
holds live tokens — scanning it would fail the hook forever over a file git will
never accept. History scanning is a CI step instead.

## CI

Two workflows, one per forge. **Forgejo reads `.forgejo/workflows` and falls
back to `.github/workflows` only when that directory is absent** — a fallback,
not a union — so the presence of `.forgejo/workflows/ci.yml` is what keeps
Forgejo off the GitHub file. Delete it and Forgejo silently starts running a
workflow written for GitHub, which is how this repo ended up with a red run
on git.hu-tao.dev.

| File | Runs on | Jobs |
|---|---|---|
| `.forgejo/workflows/ci.yml` | the VPS runner | one: `check` — the same checks, in a single job |
| `.github/workflows/ci.yml` | the GitHub mirror | two: `lint` and `evaluate` |

| Check | What |
|---|---|
| lint | `pre-commit run --all-files`, then gitleaks across the full history |
| evaluate | evaluates both `nixosConfigurations`, then `nix flake check --no-build`, then builds deploy-rs's `deploy-schema` and the runner firewall's `runner-firewall-ordering` |

The two differ in exactly two ways, both forced:

- **Job layout.** The runner's `cache:` is off and its `valid_volumes`
  allow-list has no nix store entry, so nothing survives between runs and every
  job rebuilds the `.#ci` shell from the binary cache. One job pays that once;
  the mirror's two jobs pay it twice, which is free on GitHub and is not free
  here.
- **Actions, or none at all.** The Forgejo job runs on the `nix` label —
  `nixos/nix`, which already contains Nix — so there is no
  `cachix/install-nix-action` to run and no Nix to download per run. That image
  carries no node, and every JavaScript action is executed by a node binary
  inside the job container, so the Forgejo file has no `uses:` whatsoever and
  does its own `git fetch` in place of `actions/checkout`.

  The image is not only a saving, it is the fix: on `ubuntu-latest`
  (`node:22-bookworm`) `install-nix-action` exits 127, because the branch it
  takes without systemd runs `sudo mkdir -p /etc/nix` and that image has no
  sudo. The job is already root, so the sudo bought nothing to begin with.

  A workflow here that *does* want an action must name the host:
  `uses: owner/repo` alone resolves against `[actions] DEFAULT_ACTIONS_URL`,
  which defaults to `https://data.forgejo.org` — that host mirrors `actions/*`
  and nothing third-party, so a bare `cachix/install-nix-action` fails with
  `remote: Not found`. Setting `DEFAULT_ACTIONS_URL` to `https://github.com`
  instead would fix it instance-wide, at the cost of making every bare `uses:`
  resolve to whoever holds that name on an open-registration forge.

`permissions:` is a GitHub-only field: Forgejo ignores it with a workflow
warning, which is why the Forgejo file omits it rather than carrying a line
that does nothing.

Evaluation, not a build, in both: it catches what actually breaks this repo —
a typo'd option, a missing module argument, an infinite recursion — without
asking a CI runner to realise a multi-gigabyte closure.

`--no-build` is load-bearing. deploy-rs's `deploy-activate` check references the
system closure, so a plain `nix flake check` builds the whole system, and since
deploy-rs `follows` our nixpkgs its binary is a cache miss and is compiled from
source — 5+ minutes on *every* run, on both forges, because neither runner
keeps a nix store between runs. `deploy-schema` is built separately: it is the half that
validates `deploy.json` and it needs only check-jsonschema.

**The mirror is push-only.** Commit here and let it flow across; anything edited
on GitHub is overwritten by the next sync, and CI can lag a push until Forgejo's
mirror job runs (*Synchronize Now* in the repo's mirror settings).

## Running

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

## Provisioning

`tofu/` creates the Hetzner server, installs this flake onto it with
nixos-anywhere, attaches the edge firewall and publishes DNS. It uses
**OpenTofu, not HashiCorp Terraform** — `.terraform.lock.hcl` pins providers
from `registry.opentofu.org` and the `terraform` binary rewrites those to
`registry.terraform.io` without asking.

```sh
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
$EDITOR tofu/terraform.tfvars          # fill in every placeholder

tofu -chdir=tofu init
tofu -chdir=tofu plan
tofu -chdir=tofu apply
```

Three things worth knowing before the first apply:

- **`nixosConfigurations.vps-hetzner` is what gets installed**, not `vps`.
  Hetzner Cloud presents the root disk as `/dev/sda` and the local QEMU VM gets
  `/dev/vda`; that one line is the only difference between the two, and
  installing the wrong one fails at disko.

- **`nix run .#install -- root@<ip>` puts the age key on the target** before its
  first boot, via nixos-anywhere's extra-files mechanism, and refuses to start if
  that key cannot decrypt `secrets.yaml`. Without the key, activation cannot
  decrypt anything and the machine boots with no credentials at all.

- **The primary IP is its own resource** with `auto_delete = false` and
  `prevent_destroy`. Every A record points at it and the SPF record hard-codes
  it, so it has to outlive the server: rebuilding the machine then keeps the
  address and DNS never moves. `tofu destroy` will refuse on it, by design.

### State recovery — a fresh clone, or a lost state file

The state file is gitignored, so a clone has none. `apply` from no state builds a
*second* server and moves DNS to it. Nothing is typed by hand to prevent that:
`tofu/imports.tf` carries an `import` block for every live resource, inert while
state already tracks them, active when it does not.

```sh
tofu -chdir=tofu init
tofu -chdir=tofu plan
```

A correct recovery plan reads **exactly**

```
Plan: 20 to import, 0 to add, 1 to change, 0 to destroy.
```

where the one change is `hcloud_server.vps` gaining three provider-side booleans
(`ignore_remote_firewall_ids`, `keep_disk`, `shutdown_before_deletion`) that the
importer never sets and the provider's Update never sends — applying them is a
state write and one GET. Anything else in that plan means stop and read
`tofu/imports.tf`.

**A non-zero plan against infrastructure you know is unchanged means the state
is wrong, not the infrastructure.** Never resolve an unexpected diff with a plain
`apply`. On 2026-09-05 a plan after import showed `public_net` as an addition on
the server; applying it detached the mail IP from a running host. `server.tf`
now ignores that block for exactly this reason.

## Not in this repo

Restore or regenerate these. Without them a clone will not deploy.

| What | Where | Notes |
|---|---|---|
| `secrets.yaml` | committed but encrypted | Template is `secrets.example.yaml`; the age key it is encrypted to is not here |
| age private key | `~/.sops-nix/key.txt`, and `/var/lib/sops-nix/key.txt` on the host | Must be a recipient in `.sops.yaml`. Lose every recipient and the secrets are unreadable |
| restic password | `backups/restic_password` in `secrets.yaml` | The repository password **is** the encryption key. Lose it and every snapshot is permanently unrecoverable — keep a copy outside this repo |
| DKIM private key | `email/dkim_private_key` | Its public half is published from `tofu/`. Cannot be regenerated without republishing DNS, and a mismatch fails DKIM at every recipient |
| `tofu/terraform.tfvars` | gitignored | Template is `tofu/terraform.tfvars.example` |
| Mail store, forgejo repos, minecraft world | docker volumes under `/var/lib/docker/volumes` | Restore before the first boot of a rebuilt host, or the services initialise blank |
| Every postgres database | `pg_dumpall` under `/var/backup/postgresql`, inside the same restic repository | `zstd -d < all.sql.zstd \| psql -U postgres`. Restore **before** the bot's first start, or its sqlx migrations initialise an empty schema and the dump then collides |

## Operations

```sh
systemctl list-units 'docker-*'
journalctl -u docker-forgejo -f           # every container logs to the journal

systemctl status acme-renew-hu-tao.dev.timer  # renews well before expiry; a no-op most days
systemctl start acme-hu-tao.dev.service   # force a renewal check

systemctl status restic-backups-b2.timer restic-backups-minecraft.timer
restic-b2 snapshots                       # wrapper with the repo and password wired in

systemctl status postgresqlBackup.timer   # 23:15, deliberately BEFORE restic's 00:00-01:00 window
systemctl start postgresqlBackup          # dump every database now
psql -h 127.0.0.1 -p 6432 -U serenity serenity_bot   # through pgbouncer, from the tailnet

fail2ban-client status forgejo-ssh
nft list table inet f2b-table             # where the bans actually are
nft list table inet nixos-fw

systemctl status vuln-scan.timer          # Saturdays 06:00 UTC
systemctl start vuln-scan                 # run one now — it posts to Discord
journalctl -u vuln-scan -n 50
```

The vulnerability scan covers every image declared in
`virtualisation.oci-containers` — running or not, so a stopped container is still
scanned — plus the NixOS system closure, which is what covers tailscale, sshd,
docker and the kernel. It posts at most two Discord messages and attaches the
complete report as a single markdown file.

Findings are ranked by **EPSS and CISA KEV, not CVSS**. CVSS scores how bad a bug
would be if exploited and says nothing about whether anyone is exploiting it:
CVE-2025-68121 is rated 10.0 by NVD and sits at the 52nd percentile of exploit
probability. The channel only shows what is in KEV or above the EPSS percentile
for its severity (critical p90, high p95, medium p98, low p99), which is also
what keeps Debian's perpetual "affected, will not fix" entries and CPE collisions
out of it. Everything else is still in the attachment.

A scan that cannot run reports a failure — it never degrades into an all-clear.
If a run dies before reporting, an exit trap posts an ABORTED notice, because
silence and "no findings" must not look the same.

The weekly minecraft job stops both worlds' servers, snapshots, and starts them
again from `ExecStopPost` — so they come back whether restic succeeded or not. A live
world is not consistent on disk: the server holds region files open and writes
them in place, which is why the daily backup excludes that volume and this job
exists.
