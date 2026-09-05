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
| `caddy` | 80/443 (+443/udp); TLS terminator for the four sites below |
| `cloudflared` | Tunnel connected, but **nothing routes through it** — `git`/`music`/`mail`/`smtp` are unproxied A records straight to the VPS, so caddy serves them directly |
| `mailserver` | SMTP/IMAP direct on 25, 465, 587, 993 — an MX must reach the host |
| `webmail` | roundcube, proxied at `mail.` |
| `forgejo` | **SSH on 22**, so clone URLs need no port; HTTP via caddy at `git.` |
| `navidrome` | `127.0.0.1:4533`, reached only through caddy at `music.` |
| `kuma` | proxy network only, reached at `status.` |
| `dozzle` | 8080, tailnet only |
| `grafana` | host networking, :3000, tailnet only |
| `tempo` | host networking, OTLP 4317/4318 bound to `0.0.0.0`; kept private by the firewall's input chain, not by the bind address |
| `minecraft` | 25565; RCON on loopback only |
| `serenity-bot-0` | **nothing published**; an outbound Discord gateway client, on the `botnet` network. tokio-console on `127.0.0.1:6669` |
| `serenity-redis` | `botnet` only, no published port, no volume — a cache with a Discord fallback |
| `postgres` | not a container — a host service; unix socket + loopback only, never on `botnet` |
| `pgbouncer` | not a container — a host service; 6432, reachable from `botnet` and the tailnet, kept private by the firewall's input chain |
| `syncthing` | not a container — a host service; GUI on 8384, tailnet only |

Forgejo owns port 22, so **the host's sshd is on 2222** and normal access is over
Tailscale SSH. Keeping 22 is what lets git remotes stay portless: ssh has no
service discovery — it reads no `SRV` record — so anything else has to be spelled
out in every clone URL or every client's `~/.ssh/config`.

## The things that will bite you

Five, all of them load-bearing, all of them silent when wrong.

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
  the first deploy.

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
| `grafana/admin_user`, `grafana/admin_password` | anonymous Admin is off, so this is the only way in |
| `kuma/healthcheck_url` | the out-of-band status-page probe; a separate check from the backup one because they fail for different reasons |
| `minecraft/rcon_password` | RCON is loopback-only but it is still a remote console |
| `serenity/bot_token`, `serenity/ai_api_key` | the Discord bot's gateway token and its DeepSeek key |
| `serenity/db_password` | one password, two consumers: `ALTER ROLE` in postgres and the pgbouncer userlist, both rendered from this key |

`acme_email` is **gone** from the secret set: `security.acme` needs it at
evaluation time and a registration contact is not a credential. It is
`infra.acmeEmail` in `modules/options.nix`.

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
| [docs/deploying.md](docs/deploying.md) | The three paths: redeploy, first deploy, bare metal — and the settings that make a bare-metal install actually automatic |
| [docs/migration.md](docs/migration.md) | Moving this stack from the old Ubuntu/Ansible box: data mapping, ordering, the primary-IP cutover, rollback |

## Development

```sh
nix develop
```

Or `nix develop -c zsh` if you're on zshell.

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

`.github/workflows/ci.yml`, running on the GitHub mirror rather than on a Forgejo
runner. Forgejo Actions is enabled server-side (`FORGEJO__actions__ENABLED`), but
a runner would put nix builds and a polling daemon on the box that serves mail.

| Job | What |
|---|---|
| `lint` | `pre-commit run --all-files`, then gitleaks across the full history |
| `evaluate` | evaluates both `nixosConfigurations`, then `nix flake check --no-build`, then builds deploy-rs's `deploy-schema` |

Evaluation, not a build: it catches what actually breaks this repo — a typo'd
option, a missing module argument, an infinite recursion — without asking a CI
runner to realise a multi-gigabyte closure.

`--no-build` is load-bearing. deploy-rs's `deploy-activate` check references the
system closure, so a plain `nix flake check` builds the whole system, and since
deploy-rs `follows` our nixpkgs its binary is a cache miss and is compiled from
source — 5+ minutes on *every* run, because a GitHub runner starts with an empty
nix store each time. `deploy-schema` is built separately: it is the half that
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

The weekly minecraft job stops the server, snapshots, and starts it again from
`ExecStopPost` — so the server comes back whether restic succeeded or not. A live
world is not consistent on disk: the server holds region files open and writes
them in place, which is why the daily backup excludes that volume and this job
exists.
