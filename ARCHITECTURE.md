# Architecture

How this box is put together and *why* it is put together that way. [README.md](README.md)
is the operator's manual — quick start, per-service exposure, day-to-day
commands. This document is the map: the trust boundaries, the data paths, the
deploy and state model, and the failure modes that shaped the design.

The guiding rule, stated once so the rest follows from it: **there is no state
on the server that this repo does not describe.** One flake builds the whole
machine; OpenTofu creates the machine and publishes its DNS. Anything a human
would otherwise have to remember to run is a systemd unit instead.

---

## 1. Two configurations, one line apart

`flake.nix` builds one system two ways through `mkVps`:

| Config | Root disk | Used by |
|---|---|---|
| `nixosConfigurations.vps` | `/dev/vda` (virtio) | the local QEMU test VM (`nix run .#default`) |
| `nixosConfigurations.vps-hetzner` | `/dev/sda` | what tofu/nixos-anywhere installs, and what `deploy .#vps` activates |

They differ in exactly one attribute — the disko device — and share every
module, every container, every secret. `vps-hetzner` is the real system;
`vps` exists so the same closure can be booted and tested locally.

Inputs are minimal and all `follows` nixpkgs (`nixos-26.05`): `disko` (disk
layout), `sops-nix` (secrets), `deploy-rs` (the deploy circuit breaker).

---

## 2. Boot and disk

The disk is GPT with three partitions (`disk-config.nix`): a 1 M `EF02` BIOS-boot
partition, a 1 G `EF00` ESP mounted at `/boot`, and ext4 root filling the rest.

Two hardware facts drive this and are not preferences:

- **GRUB, configured for BIOS *and* UEFI** (`boot.nix`). Hetzner Cloud boots
  these VMs in **legacy BIOS mode** — the running machine has no
  `/sys/firmware/efi`. systemd-boot is EFI-only and would install cleanly, then
  leave an unbootable box on first reboot. GRUB embeds its core image in the
  `EF02` partition (BIOS chain-loads it) *and* writes `/EFI/BOOT/BOOTX64.EFI`
  (the fallback UEFI firmware looks for with no NVRAM entry), so the same
  closure boots either way. `canTouchEfiVariables = false`, because there is no
  efivarfs in BIOS mode.
- **virtio kernel modules in the initrd** (`hardware.nix`). NixOS's default
  `availableKernelModules` targets bare metal and contains *no* virtio drivers.
  Hetzner presents the disk over virtio, so without these the initrd cannot see
  `/dev/sda`, cannot mount root, and drops to an emergency shell — while the
  provider still reports the server `running`. The nixos-anywhere `--vm-test`
  cannot catch this; the test harness injects its own virtio modules.

The ESP is 1 G, not 512 M, because it *is* `/boot` and holds a kernel + initrd
per generation. It cannot be grown without a reinstall, and filling it breaks
the next deploy rather than the current boot.

---

## 3. Trust boundaries and network topology

Traffic reaches this box through three doors, and each service sits behind
exactly one of them.

```
                    Internet
                       │
        ┌──────────────┼───────────────────────────┐
        │              │                            │
   Hetzner edge firewall (tofu/modules/hetzner-firewall)   ← door 1: the allow-list
        │              │                            │
   host nftables (modules/firewall.nix)             │      ← door 2: input + forward
        │              │                            │
   ┌────┴────┐   ┌─────┴──────┐              ┌──────┴───────┐
   │ host    │   │ DNAT →      │              │ tailscale0   │  ← door 3: the tailnet
   │ sshd    │   │ forward →   │              │ (accepted    │
   │ :2222   │   │ containers  │              │  wholesale)  │
   └─────────┘   └─────────────┘              └──────────────┘
                       │                             │
              ┌────────┴────────┐          grafana:3000, tempo OTLP,
              │ docker networks │          dozzle:8080, pgbouncer:6432,
              │  proxy / botnet │          syncthing GUI:8384, and caddy's
              └─────────────────┘          second listener on :8443
```

### The two firewalls

The edge firewall (`tofu/`) and the host firewall (`modules/firewall.nix`) are
kept deliberately similar: **each is what survives a misconfiguration of the
other.** A port opened at one but not the other is still closed. When something
is unreachable, check both.

### input vs forward — the single most load-bearing fact

A published container port is **DNAT'd in prerouting and then forwarded** — it
never touches the input hook. Docker writes its own accepts into the `ip filter`
table; in nftables *every* table's chain runs, and an accept in docker's table
cannot rescue a packet that `table inet nixos-fw` drops. So:

- A service's **published port belongs in the forward allow-list**, not input.
  Getting it backwards yields a port the internet can reach that the firewall
  never authorised.
- **Host-namespace services** (sshd on 2222, grafana, tempo, pgbouncer,
  syncthing) are on the **input** hook.
- `networking.nftables.flushRuleset` **must stay false**. The default flushes
  the entire ruleset — including the tables docker owns — on every reload, and
  docker only rebuilds them when `dockerd` starts. The symptom is latent: running
  containers keep working, the *next* container start fails with
  `iptables: No chain/target/match by that name`, and recovery is
  `systemctl restart docker`.

This boundary is also why fail2ban jails for containerised services set
`chain_hook = forward` (see §11 for the sharp edge that carries).

### Docker networks

| Network | Subnet | Purpose |
|---|---|---|
| `proxy` | docker's pool | caddy resolves its upstreams here by container name over docker's embedded DNS — no IP addresses in the Caddyfile |
| `botnet` | `172.30.0.0/24` (pinned) | the discord bot + its redis, isolated from the proxy. Pinned because `infra.botGateway` (172.30.0.1) is a literal in the bot's `DATABASE_URL`, its OTLP endpoint, and the firewall's input rule |

`modules/containers/default.nix` creates each network as a oneshot systemd unit
that every container on it `requires`, so a container can never start onto a
network that does not exist yet.

### Tailscale

`--ssh` is on, so administrative access is Tailscale SSH. The tailnet interface
is accepted wholesale on the input hook, which is how the tailnet-only services
(grafana, tempo, dozzle, pgbouncer, syncthing GUI) are kept private — by the
*absence* of an internet rule, not by their bind address. Several bind
`0.0.0.0` and rely entirely on this.

Three of them also answer by name — `dozzle.`, `grafana.` and `syncthing.` —
and that is the same mechanism wearing a hat. Caddy runs a **second listener**
on `infra.tailnetHttpsPort` (8443) carrying those three vhosts and nothing else;
like every other private port it is published on `0.0.0.0` and kept private by
being in neither allow-list. What makes the URL portless is a `nat` chain at
priority **-110**, ten ahead of docker's `dstnat`, rewriting port 443 arriving
on `tailscale0` onto it. Getting that priority wrong is silent: docker DNATs the
packet to caddy's *public* listener first and the name 404s.

The names are plain A records to the box's `100.x` address
(`tofu/modules/cloudflare-dns`). A CNAME to the node's MagicDNS name would
avoid that literal — the trap `modules/containers/tempo.nix` documents — but
Tailscale does not publish `<node>.<tailnet>.ts.net` in public DNS (verified
2026-09-17: empty answers from 1.1.1.1, 9.9.9.9 and 8.8.8.8), so it resolves
only on a device whose MagicDNS is active and fails silently on one where it is
not. The literal is the lesser failure: it goes stale only when the machine is
replaced, and it goes stale loudly. The certificate covers the names as
ordinary SANs, because DNS-01 never asks whether a name resolves publicly.

Two of the three backends are in the host's own namespace, so caddy — a
container — reaches them at `infra.dockerBridgeGateway`, which is why the input
chain has a rule for 3000 and 8384 from `br-*`.

The full port/exposure map is the Services table in [README.md](README.md#services).

---

## 4. TLS, DNS, and mail — the chain that must agree

Certificates are `security.acme` (`acme.nix`): **one** certificate named
`hu-tao.dev` with every `infra.certSubdomains` entry as a SAN, issued over
DNS-01 through Cloudflare. Because the certificate is *named* after the apex (not
after the first domain, as certbot does), reordering the SAN list cannot silently
issue a second lineage.

- caddy does **not** manage certificates. It reads the acme directory read-only;
  each site names its files explicitly (`tls fullchain.pem key.pem`), which turns
  off caddy's own management. NixOS names the key `key.pem`, not certbot's
  `privkey.pem`.
- DNS-01 only touches `_acme-challenge` TXT records, so no name on the
  certificate needs an A record or a reachable port 80 — which is why the apex
  itself can be on it.
- The cert directory is group-owned by `caddy` (not `acme`), so the unprivileged
  caddy container reads it by group membership rather than by `CAP_DAC_OVERRIDE`,
  which it drops. `reloadServices` restarts caddy and the mailserver after a
  renewal.

**Mail deliverability depends on three things agreeing**, and they are set in
three different places:

```
   PTR (rDNS)              ==   DMS container hostname   ==   MX target
   tofu/rdns.tf                 mailserver.nix                Cloudflare MX
   smtp.hu-tao.dev              smtp.hu-tao.dev               smtp.hu-tao.dev
```

The PTR belongs to the **primary IP**, not the server, which is what makes an
IP handover carry mail reputation to a new box with no DNS change (see §9 of
[docs/migration.md](docs/migration.md)). SPF is `-all` and hard-codes the IP;
DKIM's public half is published from `tofu/` while its private half is a sops
secret mounted into DMS — the two must be halves of one key or every recipient
fails the signature. DMARC is `p=quarantine`.

SMTP/IMAP (25/465/587/993) are published **directly** — an MX must be reachable
at the host, so none of it can sit behind cloudflared. Only the webmail is
proxied, at `mail.`.

---

## 5. The service stack

Containers are `virtualisation.oci-containers` (docker backend), one module per
service under `modules/containers/`. Two conventions hold across all of them
(`containers/default.nix`):

- **Data is a named docker volume**, never a bind-mounted host directory — so
  restic covers a new service the moment it declares a volume (§8).
- **Config comes from the Nix store**, read-only (0444). A store path changes
  with its content, so systemd recreates the container on a config-only change —
  which is what the Ansible setup's `recreate: always` was working around.

Restart policy is forced to `always`, and logs go to the journal (never
json-file — that would put unbounded logs on the disk and break the forgejo jail
which reads the journal).

**caddy** is the one container not pulled from a registry: it is built locally
with the `caddy-ratelimit` module compiled in (`caddy.withPlugins`, wrapped in a
minimal `dockerTools` image), because stock caddy has no rate limiting. It is
still caddy 2.11.4 — the version tracks nixpkgs, which matches the tag the
official image used — and keeps the full container hardening (non-root uid from
`ids.nix`, read-only rootfs, `--cap-drop=ALL`, tmpfs for `/data` `/config`
`/tmp`). See §6 for the uid and §7 for how `search.` is protected.

**Not containers** — three host services, deliberately:

- **postgres + pgbouncer** (`postgres.nix`) — the first service whose data is
  *not* a docker volume, so its backup (pg_dumpall) is not optional; it is the
  only thing covering that data. On the host so a second service can share it
  without either owning the other's volume. postgres is unix-socket/loopback
  only; pgbouncer (6432) is reachable from `botnet` and the tailnet.
- **syncthing** (`syncthing.nix`) — a *user* service with state in
  `~/.config/syncthing` and folders under `~/syncthing`, paths kept
  byte-identical to the old box because navidrome bind-mounts
  `~/syncthing/Music` and the node's device ID is derived from the TLS keypair in
  the config dir. Tailnet-only GUI on 8384.

---

## 6. Identity model

`modules/ids.nix` assigns uids/gids to services that run under their own account,
as `base (1_000_000) + offset`, from a hand-maintained **append-only** table.
The base clears every allocator the host uses (system users, nixbld, DynamicUser,
subuid blocks); the ceiling (2097151) is the largest uid a ustar/tar header can
hold, which matters because these uids end up in restic snapshots.

The numbers are *assigned*, not hashed from the service name: a hash becomes
immutable the moment the first file is written and a rename silently orphans it.
Read `config.infra.serviceId.<name>`, never a literal — so `grep -rn serviceId`
finds every use.

Today only `caddy` has an id (offset 1). A group per id is created so
`security.acme` can chown the cert directory to `caddy` rather than to `acme`.

---

## 7. Access control per site

Every service has exactly one gate, and they differ by what the service itself
supports:

| Service | Gate |
|---|---|
| grafana | real login from sops; anonymous-Admin off, sign-up off |
| dozzle | bcrypt hash from sops, in a `users.yml` copied to a stable path |
| minecraft RCON | password from sops, loopback only; one password per world (25575 / 25576) |
| serenity bot | discord token + AI key + db password, all sops |
| **kuma** | **no seeding mechanism** — the first visitor creates the admin account and the route then closes. Create it immediately after the first deploy. |
| **searxng** | **no accounts at all** — caddy's `basic_auth` is the entire access control; the bcrypt hash is a sops secret handed to caddy via an env file |

searxng is the interesting one. It has no concept of a user, so authentication
is the proxy's job:

- caddy's `basic_auth` on the `search.` site is the only thing between the
  instance and the internet. The credential is passed through caddy's own
  `{$VAR}` env substitution from a sops-rendered env file — **not** a Nix string,
  because the Caddyfile is a world-readable store path and a bcrypt hash there is
  one anyone with a shell could crack.
- basic_auth runs a cost-14 bcrypt on **every** request, and searxng's
  `image_proxy` pulls many thumbnails per results page *through* caddy — so a
  password flood could turn bcrypt into CPU exhaustion. caddy's `rate_limit`
  (the compiled-in module, §5) caps hits per client IP and returns 429 *before*
  the bcrypt runs, ordered `before basic_auth`. It is in-process: a misconfig
  throttles requests, it cannot take the box down (contrast §11).

The env file is read by docker at container *start*, so it re-resolves the sops
generation symlink each time — a *mounted* template would pin a stale inode (§10).

---

## 8. Data and backups

```
  docker volumes ─────────────┐
  /var/lib/docker/volumes      │
                               ├──▶ restic ──▶ Backblaze B2   (daily, 00:00–01:00)
  pg_dumpall                   │              keep 7d / 4w / 6m
  /var/backup/postgresql ──────┘
       ▲ (23:15, BEFORE restic)

  minecraft_data  ─┬▶ restic (weekly, servers STOPPED) ── excluded from the daily job
  minecraft2_data ─┘
```

`services.restic` backs up `/var/lib/docker/volumes` **wholesale**, so a service
added later is covered the moment it declares a volume — a backup that has to be
told about each new service eventually stops covering one. postgres runs on the
host, so its data is not under docker/volumes; `services.postgresqlBackup` writes
a `pg_dumpall` there (every DB + globals) at **23:15**, deliberately before
restic's window, so the archived dump is never up to 23 h stale.

The minecraft worlds are snapshotted **separately, with the servers stopped** —
a live world holds region files open and is not consistent on disk. That job
stops the containers in `backupPrepareCommand` and restarts them from
`backupCleanupCommand` (an `ExecStopPost`), so the servers return whether restic
succeeded or not. They are excluded from the daily job.

Both worlds share **one** job and therefore one downtime window: a second job
would mean a second stop/start cycle and a second restic run against the same
repository. Every world volume must be in this job's `paths` **and** in the
daily job's `exclude` — a volume missing from the exclude list is archived hot
by the daily run, which is the corruption this job exists to prevent.

The restic **password is the encryption key**: lose it and every snapshot is
unrecoverable. It, and the other things not in this repo, are catalogued in
[README.md → Not in this repo](README.md#not-in-this-repo).

---

## 9. Secrets

sops + age (`secrets.nix`). The age private key lives at
`/var/lib/sops-nix/key.txt` on the host and is staged there **before first boot**
by `nix run .#install` — without it, activation cannot decrypt anything and the
machine boots with no credentials, its own login included.

Two kinds of consumer:

- **`sops.secrets.*`** — a decrypted file at `/run/secrets/…`, for things read as
  a file (restic password, DKIM key, db password).
- **`sops.templates.*`** — a rendered file mixing secrets with literal text, for
  things that want `KEY=value` (the acme, grafana, caddy, cloudflared,
  searxng env files).

**Every key in `secrets.nix` must exist in `secrets.yaml`** or
`sops-install-secrets` fails during activation. `acme_email` is deliberately
*not* a secret — `security.acme` needs it at eval time and a contact address is
not a credential; it is `infra.acmeEmail`.

The stale-symlink trap: a rendered template's real path is under a generation
directory and `.path` only symlinks to it. Docker resolves a symlink at mount
time and holds that inode forever, so a rotated secret never reaches a container
that *mounts* the template. The fixes are either copy-to-a-stable-path first
(`dozzle-users.service`, `mailserver-dkim.service`) or pass it as an **env file**
that docker re-reads at start (caddy, cloudflared).

---

## 10. Observability

```
  bot ──OTLP──▶ tempo (host net, :4317/4318) ──▶ grafana (host net, :3000)
                                                   reads tempo; tailnet-only

  every container ──journald──▶ dozzle (:8080, tailnet)  and  journalctl

  public status page: kuma (proxy net) ─── caddy ──▶ status.<domain>
       ▲
  kuma-check timer (every 5 min) probes the PUBLIC page and pings
  healthchecks.io — because kuma cannot report its own host being down
```

tempo and grafana use host networking and are kept private by the input chain
(§3), not by their bind address. kuma publishes no port and is reached only
through caddy. The self-hosted-status-page paradox — it cannot report its own
outage — is closed by `kuma-check`, an out-of-band timer: silence becomes the
alert.

**vuln-scan** (`vuln-scan.nix`, Saturdays 06:00 UTC) scans every declared
container image (running or not) plus the NixOS system closure, ranks findings by
**EPSS + CISA KEV, not CVSS**, and posts to Discord. A scan that cannot run posts
an ABORTED notice — silence and "no findings" must never look the same.

---

## 11. Deploy and state model

Three separate mechanisms, split on purpose so none can trigger another:

| Task | Tool |
|---|---|
| create server, IPs, edge firewall, DNS, rDNS | `tofu` |
| install NixOS onto a blank machine | `nixos-anywhere` (`nix run .#install`), by hand |
| update a machine already running NixOS | `deploy .#vps` |

The nixos-anywhere module used to live in `tofu/` and was **removed**: its
`null_resource` runs a full install on *creation*, which any plan without it in
state (a fresh clone, a lost state file, a `state rm`) silently proposes —
i.e. "reinstall the running mail server." Infrastructure and OS install are now
separate so an `apply` can never do it.

### deploy-rs — the circuit breaker

`deploy .#vps` builds locally, pushes the closure, activates, then **reconnects
on a fresh connection to confirm the box is still reachable**. If it cannot, the
machine rolls itself back unattended. That is the whole reason it is here — it is
the only thing that saves you from a firewall/sshd/networking change that locks
you out. It confirms **reachability, not service health**: a crashlooping
container is *not* rolled back (you still have ssh; fix it forward). `nixos-rebuild
--target-host` is the dependency-free fallback, minus the confirmation step.

deploy reaches the host sshd on **2222** with a real key — Tailscale SSH's
interactive re-auth cannot be scripted, so it is bypassed for deploys.

### tofu state recovery

State is gitignored (it holds every value tofu ever read). A clone has none, and
`apply` from no state builds a *second* server and moves DNS to it. `tofu/imports.tf`
prevents that declaratively: an `import` block per live resource, inert while
state tracks it, active when it does not. `tofu init && tofu plan` then rebuilds
state. A correct recovery plan is **`20 to import, 0 to add, 1 to change, 0 to
destroy`** — the one change being three provider-side booleans on
`hcloud_server.vps` that the importer never sets. **Anything else means stop.**

The sharp edge here (learned the hard way, 2026-09-05): the hcloud provider never
reads `public_net` into state, so a post-import plan proposes *adding* it — and on
this resource that detaches the primary IPs before reattaching. Applying it once
took the mail IP off a running host. `server.tf` now carries
`lifecycle.ignore_changes = [public_net]` so the block can never become an action.
The primary IP is its own resource with delete protection precisely so a mistake
here is minutes of downtime, not a lost address.

---

## 12. Failure modes and recovery

The design is shaped by which failures roll back automatically and which do not.

| Failure | Caught by | Recovery |
|---|---|---|
| firewall / sshd / networking change locks you out | **deploy-rs auto-rollback** | automatic |
| unbootable kernel / initrd | GRUB generation menu (5 s at boot) | pick previous generation |
| a container fails to start | nothing — deploy confirms reachability, not health | `nixos-rebuild --rollback` or fix forward |
| `nftables` reload wiped docker's chains | nothing automatic; symptom is the *next* container start failing | `systemctl restart docker` (and keep `flushRuleset = false`) |
| a rotated sops secret didn't reach a container | nothing — the container holds a stale inode | copy-to-stable-path or env-file pattern (§9) |
| tofu plan shows an unexpected diff on unchanged infra | you, reading the plan | **the state is wrong, not the infra** — never `apply`; `refresh`/`import`, verify on the box |
| a fail2ban jail bans a docker/bridge address | nothing — a forward-chain `reject` on an internal IP downs **every** container | `systemctl stop fail2ban`; keep private ranges in `ignoreIP`, or don't ban on the forward chain for low-value targets |
| a deploy restarts every container at once (any `nix flake update`) and one racy unit exits non-zero | **deploy-rs aborts** — and its de-activation stops every container while the rollback restores the old *configuration*, not the old *running state* | `systemctl restart docker`, then start the container units by hand — `switch-to-configuration` will refuse with `Could not acquire lock` while deploy-rs still holds it. Order fragile units behind a readiness gate, as `forgejo-runner-ready` does |

The last three rows are recent scars.

A forward-chain fail2ban jail has a blast radius the size of the whole box: if
it ever bans an internal source it rejects all forwarded traffic, not one
attacker. That is why `search.` is rate-limited **in caddy** (§7) rather than
banned in nftables — an in-process limiter can only throttle, it cannot take the
forward plane down.

The newest row is the widest of the three, and the least intuitive: a failed
activation does not leave the box on the previous generation *running*. It
leaves it on the previous generation's *configuration*, with nothing started. On
2026-09-16 a three-second transient in one non-critical container therefore cost
fifteen healthy services, mail included, for six minutes — the abort was more
destructive than the failure it was responding to. Full writeup in
[docs/postmortems/2026-09-16-flake-update-rollback.md](docs/postmortems/2026-09-16-flake-update-rollback.md).

---

## Where to look next

- [README.md](README.md) — services, the five load-bearing gotchas, deploy
  commands, CI, day-to-day operations.
- [docs/deploying.md](docs/deploying.md) — the three deploy paths in full, and
  what makes a bare-metal install actually one command.
- [docs/migration.md](docs/migration.md) — moving the stack off the old
  Ubuntu/Ansible box, including the primary-IP cutover.
- The module comments themselves. Every `modules/**.nix` opens with why it exists
  and which mistakes it is guarding against — this document is the index to them,
  not a replacement.
