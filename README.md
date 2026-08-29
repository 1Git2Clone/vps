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
├── modules/
│   ├── options.nix       # infra.* — domain, tailnet IP, proxy network
│   ├── secrets.nix       # every sops key, declared
│   ├── acme.nix          # one certificate, DNS-01 via Cloudflare
│   ├── firewall.nix      # nftables, including the container forward path
│   ├── services.nix      # sshd, tailscale, fail2ban, docker
│   ├── security.nix      # auditd rules
│   ├── backups.nix       # restic → B2, daily + weekly quiescent minecraft
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
| `tempo` | host networking, OTLP 4317/4318 bound to the tailnet address |
| `minecraft` | 25565; RCON on loopback only |

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

`acme_email` is **gone** from the secret set: `security.acme` needs it at
evaluation time and a registration contact is not a credential. It is
`infra.acmeEmail` in `modules/options.nix`.

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

- **`install-sops-key.sh` puts the age key on the target** before its first
  boot, via nixos-anywhere's extra-files mechanism. Without it, activation
  cannot decrypt anything.

- **The primary IP is its own resource** with `auto_delete = false` and
  `prevent_destroy`. Every A record points at it and the SPF record hard-codes
  it, so it has to outlive the server: rebuilding the machine then keeps the
  address and DNS never moves. `tofu destroy` will refuse on it, by design.

### Adopting the existing server

`apply` against an unimported server builds a *second* one and moves DNS to it.
Import first:

```sh
tofu -chdir=tofu import hcloud_primary_ip.main <primary-ip-id>
tofu -chdir=tofu import hcloud_server.vps 137766340
tofu -chdir=tofu import hcloud_ssh_key.main <ssh-key-id>
tofu -chdir=tofu plan       # reconcile before applying anything
```

The Cloudflare records need importing too, or the provider will try to create
records that already exist — v5 removed `allow_overwrite`, so there is no
quiet-adoption path any more.

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

## Operations

```sh
systemctl list-units 'docker-*'
journalctl -u docker-forgejo -f           # every container logs to the journal

systemctl status acme-renew-hu-tao.dev.timer  # renews well before expiry; a no-op most days
systemctl start acme-hu-tao.dev.service   # force a renewal check

systemctl status restic-backups-b2.timer restic-backups-minecraft.timer
restic-b2 snapshots                       # wrapper with the repo and password wired in

fail2ban-client status forgejo-ssh
nft list table inet f2b-table             # where the bans actually are
nft list table inet nixos-fw
```

The weekly minecraft job stops the server, snapshots, and starts it again from
`ExecStopPost` — so the server comes back whether restic succeeded or not. A live
world is not consistent on disk: the server holds region files open and writes
them in place, which is why the daily backup excludes that volume and this job
exists.
