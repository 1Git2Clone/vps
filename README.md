# VPS Architecture

[![CI Icon]][CI Status]&emsp;[![Pages Icon]][Pages Status]&emsp;[![Handbook Icon]][Handbook]&emsp;[![Status Icon]][Status]&emsp;[![NixOS Icon]][NixOS]

[CI Icon]: https://git.hu-tao.dev/hutao/vps/badges/workflows/ci.yml/badge.svg
[CI Status]: https://git.hu-tao.dev/hutao/vps/actions
[Pages Icon]: https://git.hu-tao.dev/hutao/vps/badges/workflows/pages.yml/badge.svg
[Pages Status]: https://git.hu-tao.dev/hutao/vps/actions
[Handbook Icon]: https://img.shields.io/badge/docs-handbook-7aa2f7
[Handbook]: https://pages.hu-tao.dev/hutao/vps/docs/
[Status Icon]: https://img.shields.io/badge/uptime-status%20page-7aa2f7
[Status]: https://status.hu-tao.dev/status/all
[NixOS Icon]: https://img.shields.io/badge/NixOS-26.05-7aa2f7
[NixOS]: https://git.hu-tao.dev/hutao/vps/src/branch/main/flake.nix

One flake that describes a whole VPS — disks, firewall, secrets, every
container service — plus a second machine that runs its CI, and the OpenTofu
that creates both and publishes their DNS.

Ported from the Ansible repo it replaces. What that repo needed three layers for
(docker's restart policy, a boot-time `docker-services.sh` sweep, and an Ansible
converge run from a workstation) is one layer here: systemd units built from this
flake. There is no state on the server that this repo does not describe, and
nothing to remember to run.

```text
.
├── configuration.nix     # the import list, nothing else
├── disk-config.nix       # disko layout + the local QEMU VM
├── flake.nix             # vps, vps-hetzner and runner-hetzner
├── .pre-commit-config.yaml  # the checks, shared by the commit hook and CI
├── .markdownlint-cli2.yaml  # what the markdown linter checks, and what it skips
├── .forgejo/workflows/   # CI and pages, run on the dedicated runner box
├── .github/workflows/    # CI, run on the GitHub mirror
├── docs/                 # the handbook — mdBook source in docs/src/
├── runner/               # the CI runner's own configuration.nix
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
│   ├── pages-pull.nix    # fetches published artifacts into the pages volume
│   ├── boot.nix hardware.nix networking.nix nix.nix users.nix
│   ├── runner/           # everything only the CI runner has
│   └── containers/       # one module per service
└── tofu/                 # hcloud server + edge firewall, Cloudflare DNS
```

## The handbook

Everything below is the short version. The long version — how a packet reaches
a service, why the CI runner is a separate machine, what to do when a deploy
aborts — is in `docs/`, published at
**<https://pages.hu-tao.dev/hutao/vps/docs/>**.

```sh
nix develop -c mdbook serve docs --open
```

| Chapter                                                          | For                                                                |
| ---------------------------------------------------------------- | ------------------------------------------------------------------ |
| [Network and trust boundaries](docs/src/architecture/network.md) | the three doors, input vs forward, why there is no private network |
| [CI runner isolation](docs/src/architecture/runner.md)           | the seven layers, the one-way rule, the four-path allow-list       |
| [The service stack](docs/src/architecture/services.md)           | what runs, and how each thing is reached                           |
| [Deploying](docs/src/operations/deploying.md)                    | the everyday path, and the circuit breaker behind it               |
| [Failure modes and recovery](docs/src/operations/recovery.md)    | what rolls back on its own and what does not                       |
| [Runbook](docs/src/operations/runbook.md)                        | the commands, in the order you want them                           |

Those links go to the source, which renders fine in Forgejo — diagrams
included, since they are mermaid and Forgejo draws them natively.

## Quick start

```sh
nix develop                       # the shell everything below assumes
deploy .#vps                      # the VPS
deploy .#forgejo-runner           # the CI runner, via ProxyJump through the VPS

QEMU_OPTS="-vnc :0" nix run .#default    # the whole system, locally
nix develop -c pre-commit install        # once per clone
```

Two machines: the VPS holds every service, and a second box runs CI and is
treated as hostile. See [the introduction](docs/src/introduction.md).

## The things that will bite you

Six, all of them load-bearing, all of them silent when wrong.

**A published container port lives in the forward chain, not input.** It is
DNAT'd in prerouting and then forwarded, so it never touches the input hook.
Docker writes its own accepts into the `ip filter` table, and in nftables every
table's chain runs — an accept over there cannot rescue a packet `table inet
nixos-fw` drops. So a policy-drop forward chain with no rules leaves every
container unreachable _and_ without egress. When adding a service, its port goes
in the forward allow-list; getting that backwards gives you a port the internet
can reach that the firewall never authorised.

**fail2ban's `chain = DOCKER-USER` does not translate.** That is the right answer
for iptables. With `networking.nftables` on, NixOS resolves
`banaction-allports` to `nftables-allports`, where `chain` is only the nftables
_chain name_ — so `DOCKER-USER` would name an input-hooked chain and ban nothing
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
is a stable path, so rotating a value changes the file's _content_ and nothing
else — the unit text is byte-identical and `switch-to-configuration` finds no
unit to restart. The container keeps the old value in its environment until
something unrelated recreates it, which can be weeks. `restartUnits` on the
template is the fix: sops-nix diffs the rendered file and restarts only on a
real change, so no-op deploys still don't bounce the service. `navidrome.env`
does this; the older env templates predate it.

**The two firewalls must both allow a port.** `tofu/modules/hetzner-firewall` is
the edge and `modules/firewall.nix` is the host. Each is what survives a
misconfiguration of the other, so when something is unreachable, check both.

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

The Actions runner's credential is **not** in this set. It lives on the runner
box, delivered through Hetzner user-data, and that host holds no age key at all
— see [Secrets](docs/src/architecture/secrets.md).

| Key                                                   | Why                                                                                                                                                                                                      |
| ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `grafana/admin_user`, `grafana/admin_password`        | anonymous Admin is off, so this is the only way in                                                                                                                                                       |
| `kuma/healthcheck_url`                                | the out-of-band status-page probe; a separate check from the backup one because they fail for different reasons                                                                                          |
| `minecraft/rcon_password`                             | RCON is loopback-only but it is still a remote console                                                                                                                                                   |
| `minecraft2/rcon_password`                            | the second world's console. A separate password on purpose — one leak should not reach both worlds                                                                                                       |
| `serenity/bot_token`, `serenity/ai_api_key`           | the Discord bot's gateway token and its DeepSeek key                                                                                                                                                     |
| `searxng/secret_key`                                  | signs searxng's session cookies; upstream's default is the literal `ultrasecretkey`                                                                                                                      |
| `searxng/admin_user`, `searxng/admin_password_hash`   | searxng has no accounts, so caddy's `basic_auth` is the whole access control. bcrypt, same shape as dozzle's                                                                                             |
| `serenity/db_password`                                | one password, two consumers: `ALTER ROLE` in postgres and the pgbouncer userlist, both rendered from this key                                                                                            |
| `navidrome/lastfm/api_key`, `navidrome/lastfm/secret` | one Last.fm application registration, reaching the container as `ND_LASTFM_APIKEY` / `ND_LASTFM_SECRET`. Enables scrobbling server-side; each user still links their own account under Personal Settings |

`acme_email` is **gone** from the secret set: `security.acme` needs it at
evaluation time and a registration contact is not a credential. It is
`infra.acmeEmail` in `modules/options.nix`.

## Not in this repo

Restore or regenerate these. Without them a clone will not deploy.

| What                                       | Where                                                                          | Notes                                                                                                                                                                |
| ------------------------------------------ | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `secrets.yaml`                             | committed but encrypted                                                        | Template is `secrets.example.yaml`; the age key it is encrypted to is not here                                                                                       |
| age private key                            | `~/.sops-nix/key.txt`, and `/var/lib/sops-nix/key.txt` on the host             | Must be a recipient in `.sops.yaml`. Lose every recipient and the secrets are unreadable                                                                             |
| restic password                            | `backups/restic_password` in `secrets.yaml`                                    | The repository password **is** the encryption key. Lose it and every snapshot is permanently unrecoverable — keep a copy outside this repo                           |
| DKIM private key                           | `email/dkim_private_key`                                                       | Its public half is published from `tofu/`. Cannot be regenerated without republishing DNS, and a mismatch fails DKIM at every recipient                              |
| `tofu/terraform.tfvars`                    | gitignored                                                                     | Template is `tofu/terraform.tfvars.example`                                                                                                                          |
| Mail store, forgejo repos, minecraft world | docker volumes under `/var/lib/docker/volumes`                                 | Restore before the first boot of a rebuilt host, or the services initialise blank                                                                                    |
| Every postgres database                    | `pg_dumpall` under `/var/backup/postgresql`, inside the same restic repository | `zstd -d < all.sql.zstd \| psql -U postgres`. Restore **before** the bot's first start, or its sqlx migrations initialise an empty schema and the dump then collides |
