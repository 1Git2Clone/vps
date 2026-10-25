# The service stack

Containers are `virtualisation.oci-containers` (docker backend), one module per
service under `modules/containers/`. Two conventions hold across all of them
(`containers/default.nix`):

- **Data is a named docker volume**, never a bind-mounted host directory — so
  restic covers a new service the moment it declares a volume. See
  [Data and backups](data.md).
- **Config comes from the Nix store**, read-only (0444). A store path changes
  with its content, so systemd recreates the container on a config-only change
  — which is what the old Ansible setup's `recreate: always` was working
  around.

Restart policy is forced to `always`, and logs go to the journal — never
`json-file`, which would put unbounded logs on the disk and break the forgejo
jail that reads the journal.

## What runs, and how it is reached

| Service            | Exposure                                                                                                                                                                                                                                                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `caddy`            | 80/443 (+443/udp) for the public sites, and 8880/8443 for the tailnet-only ones — the second pair is kept private by its absence from the firewall's allow-lists, and nftables rewrites tailscale0's 80/443 onto it so those URLs carry no port. Built locally with the `caddy-ratelimit` module (`caddy.withPlugins`), not the stock image |
| `cloudflared`      | Tunnel connected, but **nothing routes through it** — `git`/`music`/`mail`/`smtp` are unproxied A records straight to the VPS, so caddy serves them directly                                                                                                                                                                                |
| `mailserver`       | SMTP/IMAP direct on 25, 465, 587, 993 — an MX must reach the host                                                                                                                                                                                                                                                                           |
| `webmail`          | roundcube, proxied at `mail.` on the tailnet only — the public copy 404s every path                                                                                                                                                                                                                                                         |
| `forgejo`          | **SSH on 22**, so clone URLs need no port; HTTP via caddy at `git.`; site admin (`/admin`, `/api/v1/admin`) tailnet-only                                                                                                                                                                                                                    |
| `navidrome`        | `127.0.0.1:4533`, reached only through caddy at `music.`, on the tailnet listener                                                                                                                                                                                                                                                           |
| `kuma`             | proxy network only, reached at `status.`; the admin socket only on the tailnet copy of that name                                                                                                                                                                                                                                            |
| `searxng`          | proxy network only, reached at `search.` on the tailnet listener, behind `basic_auth` with caddy `rate_limit` in front of the bcrypt                                                                                                                                                                                                        |
| `dozzle`           | `dozzle.` over the tailnet, and still 8080 directly — the direct port is deliberate, since this is what you open when caddy is the broken part                                                                                                                                                                                              |
| `grafana`          | host networking, :3000, tailnet only; also `grafana.`, which caddy reaches at the docker bridge address because host networking is invisible to docker's DNS                                                                                                                                                                                |
| `tempo`            | host networking, OTLP 4317/4318 bound to `0.0.0.0`; kept private by the firewall's input chain, not by the bind address                                                                                                                                                                                                                     |
| `mc-router`        | **25565**, the only public Minecraft port; picks the world by the hostname in the handshake and wakes it through `minecraft-scaler`. See [Worlds on demand](#worlds-on-demand-at-most-two-at-once)                                                                                                                                          |
| `minecraft`        | world 1, MC **26.1.2** on the `java25` image, the `packs/mc1` modpack; `minecraft.`, `mc.` and bare-IP joins via mc-router; no published game port. RCON on loopback only (25575). Heap 1 G floor / 6 G ceiling — see below                                                                                                                 |
| `minecraft2`       | world 2, MC **1.21.1** on the `java21` image, the `packs/mc2` zombie modpack; `mc2.` via mc-router, no published game port; RCON on loopback only (25576). Heap 1 G / 4 G                                                                                                                                                                   |
| `minecraft3`       | world 3, MC **26.2** on the `java25` image, the `packs/mc3` Vanilla+ modpack; `mc3.` via mc-router, no published game port; RCON on loopback only (25577). Heap 1 G / 4 G. Every world's `.mrpack` is also the players' download: see [How the servers are set up](../minecraft/servers.md)                                                 |
| `serenity-bot-0`   | **nothing published**; an outbound Discord gateway client, on the `botnet` network. tokio-console on `127.0.0.1:6669`                                                                                                                                                                                                                       |
| `serenity-redis`   | `botnet` only, no published port, no volume — a cache with a Discord fallback                                                                                                                                                                                                                                                               |
| `postgres`         | not a container — a host service; unix socket + loopback only, never on `botnet`                                                                                                                                                                                                                                                            |
| `pgbouncer`        | not a container — a host service; 6432, reachable from `botnet` and the tailnet, kept private by the firewall's input chain                                                                                                                                                                                                                 |
| `syncthing`        | not a container — a host service; GUI on 8384, tailnet only; also `syncthing.`, where caddy must rewrite the `Host` header or syncthing's rebinding check answers 403                                                                                                                                                                       |
| `endlessh-go`      | not a container — a host service; the SSH tarpit on 222, 2022, 2222 and 22222, on the public address only; its metrics on `127.0.0.1:2112`. See [Observability](observability.md#the-ssh-tarpit)                                                                                                                                            |
| `prometheus`       | not a container — a host service; loopback-only :9090, scraping the tarpit for grafana                                                                                                                                                                                                                                                      |
| `minecraft-scaler` | not a container — a host service; mc-router's scale webhook on the `mc` network gateway, `172.31.0.1:25580`, reachable from mc-router's address alone                                                                                                                                                                                       |

The Forgejo Actions runner is **not on this list any more**: it lives on its
own machine. See [CI runner isolation](runner.md).

### Why the Minecraft heap is two numbers

itzg's `MEMORY` sets `-Xms` **and** `-Xmx` to the same value, so the JVM commits
the whole heap at startup and never gives any of it back. That is why an idle
world with nobody on it sat at 4.38 G of RSS at 0–1% CPU. Both worlds therefore
set `INIT_MEMORY` and `MAX_MEMORY` separately — a low floor, the same ceiling as
before — rather than `MEMORY`.

The floor alone is not enough. G1 only uncommits at the end of a GC cycle, and
an idle server triggers no GCs at all, so the heap would stay at its
high-water mark forever. `-XX:G1PeriodicGCInterval=300000` (JEP 346) is the
other half: one concurrent cycle per five idle minutes, which is what actually
returns the pages. The two are a pair — either one on its own does nothing
useful.

RSS is still not heap. Metaspace, the code cache, GC structures and direct
buffers live outside `-Xmx`, so the ceiling is not a bound on what the container
reports.

### Worlds on demand, at most two at once

The box has 16 G and no swap, and mail lives on it too, so every world at its
heap ceiling at once is a job for the OOM killer. No world starts at boot.
Instead:

- **mc-router** owns 25565 and reads the hostname the player typed. A **login**
  to a sleeping world (not a server-list ping, so scanners cannot wake one)
  POSTs `{"action":"up"}` to `minecraft-scaler` and holds the player for up to
  3 minutes while the world boots. Ten minutes after the last player leaves it
  POSTs `{"action":"down"}`.
- **Only whitelisted players wake a world.** mc-router's allowlist is rebuilt
  from every world's `whitelist.json` each time it starts, so scanners that
  send a login get nowhere and no player list lives in this public repo. It
  fails closed: no readable whitelist means nobody wakes anything. mc-router
  compares the UUID the client claims; Mojang's check still happens at the
  world, which is online-mode with an enforced whitelist.
- **minecraft-scaler** turns those into `systemctl start` / `stop` of
  `docker-<world>.service`, for the worlds in `worlds` only. It runs as root
  because polkit is off, with every capability dropped and systemd's
  `IPAddressAllow` set to mc-router's address.
- **The cap** is an `ExecCondition` on each world's unit: it counts the other
  worlds that are not `inactive`/`failed` and refuses at two. Being in the
  unit, it holds for a hand-typed `systemctl start` too. A refusal skips the
  start rather than failing it, so `Restart=always` does not retry it, and the
  scaler answers 409 so mc-router drops the login instead of waiting.

What players see: a sleeping world's server-list entry says it is asleep, the
first join wakes it and usually times out, and a second join a minute later
gets in. When two worlds are already up, the join is refused until one sleeps.

The cost is that worlds see mc-router's address as every player's. Nothing
here keys on player IPs (whitelist and bans are by UUID); PROXY protocol would
fix it but needs a mod on every world.

`modules/containers/minecraft-cap.nix` holds both halves, and
`nix build .#checks.x86_64-linux.minecraft-cap -L` boots them against stand-in
worlds. A new world is a container, an entry in `worlds` in
`modules/containers/minecraft.nix`, a `MAPPING` line, and an A record in
`tofu/modules/cloudflare-dns`.

Forgejo owns port 22, so **the host's sshd is on 2222**, on the tailnet address
only, and that is the way in — Tailscale SSH is off. Keeping 22 is what lets
git remotes stay portless: ssh has no service discovery — it reads no `SRV`
record — so anything else has to be spelled out in every clone URL or every
client's ssh config.

## caddy is built here, not pulled

caddy is one of three locally built images (with pages-hook and the serenity
bot, below), and the only one built to add a module. It is built locally with
the `caddy-ratelimit` module compiled in (`caddy.withPlugins`, wrapped in a
minimal `dockerTools` image), because stock caddy has no rate limiting — and
rate limiting is load-bearing for every site, see
[Access control](access-control.md#rate-limiting-every-site-by-default).

It is still caddy 2.11.4 — the version tracks nixpkgs, which matches the tag
the official image used — and keeps the full container hardening: non-root uid
from `ids.nix`, read-only rootfs, `--cap-drop=ALL`, and tmpfs for `/data`,
`/config` and `/tmp`.

## Images are pinned where the tag moves

Most images here are `repo:tag` on a release tag, which is both a version and a
promise that the content behind it does not change. Three are not, and they
carry a digest as well (forgejo carries one too, on a release tag; the table
lists only the images whose tag itself moves):

| Image                          | Why the tag alone says nothing                                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `itzg/minecraft-server:java25` | a rolling JRE tag; a re-pull can swap the JRE under a live world                                                               |
| `itzg/minecraft-server:java21` | the same, and it matters more — world 2's mods are compiled against Java 21, and mixin/ASM on a newer JDK is the classic crash |
| `redis:8-alpine`               | a rolling minor tag                                                                                                            |

A digest also makes the
[image archive's restore](data.md#restoring-is-automatic) sound: a pinned pull
either returns those exact bytes or fails, so falling back to an archived copy
cannot silently substitute a different image.

Renovate is configured to match this. Its regex manager captures
`currentDigest` as an **optional** group — without it the tag group would
swallow the digest and leave the version unparseable — and the rule that keeps
`itzg/minecraft-server` off automatic version bumps is split so that
`matchUpdateTypes: ["digest"]` stays enabled. Before the pin, disabling that
package read as caution and meant the opposite: a rolling tag has no version to
bump, so there was nothing to be deliberate _with_, and the content moved on the
next pull with no PR ever saying so. A digest PR is that missing signal.

`docker.autoPrune` is weekly and its `flags` are empty, so it is a plain
`docker system prune` — **dangling layers only**, and never a volume. Before
it, in the same unit, `removeUnnamedImages` (`modules/containers/default.nix`)
removes every image no container in the config names. That is what clears the
old version every bump leaves behind. It is not `--all`, because `--all`
would also take the images of the sleeping Minecraft worlds, whose containers
do not exist while they sleep. The runner's podman prune is the one that
runs `--all`, and what that costs is covered in
[CI runner isolation](runner.md#the-garbage-collector-eats-it).

## Navidrome plugins are pinned too

Navidrome plugins (`.ndp`, WebAssembly) are fetched by hash in `navidrome.nix`
and mounted read-only at `/plugins`, so adding or upgrading one is a commit.
Renovate does not track them. Turning one on, and its settings, happen in the
admin UI and are stored in `navidrome_data`.

That makes `navidrome_data` hold a third-party credential:
**discord-rich-presence** logs into Discord's gateway as the user, with a
Discord _user_ token pasted into its settings. That is a self-bot by Discord's
rules and was accepted knowingly. The token is in restic's backups along
with the rest of the volume. While a track plays the plugin sets the account to
Do Not Disturb, and because `music.` is tailnet-only its cover-art option uploads
covers to `uguu.se`.

## The serenity bot is built during activation

Upstream publishes no image, so `serenity-bot.nix` builds one from upstream's
own Dockerfile off a full-SHA `fetchgit` pin. **The build runs in the
activation script, not in its unit**: that is the only phase of a switch where
the old container is still serving, so the ~3½-minute compile costs no outage.
`stopIfChanged = false` on the containers and the builder keeps them up until
then, and `serenity-bot-image.service` only does the build at boot, when docker
is not up during activation. The tag embeds the rev plus a hash of the enabled
features and rustflags, so a features-only change rebuilds too.

Sharding is two numbers, `shards` and `instances`, both 1. The per-instance
ranges are computed and checked exhaustively at eval time up to 16 shards.
**Above one instance redis stops being optional**: the AI locks and rate limits
are per-process without it. Until then `serenity-redis` is a cache with a
Discord fallback: in-memory only, no volume, 256 MB LRU.

## Deliberately not containers

- **postgres + pgbouncer** (`postgres.nix`) — the first service whose data is
  _not_ a docker volume, so its backup (`pg_dumpall`) is not optional; it is
  the only thing covering that data. On the host so a second service can share
  it without either owning the other's volume. postgres is unix-socket and
  loopback only; pgbouncer (6432) is reachable from `botnet` and the tailnet.
- **syncthing** (`syncthing.nix`) — a _user_ service with state in
  `~/.config/syncthing` and folders under `~/syncthing`, paths kept
  byte-identical to the old box because navidrome bind-mounts
  `~/syncthing/Music` and the node's device ID is derived from the TLS keypair
  in the config dir. Tailnet-only GUI on 8384.
- **CoreDNS** (`caddy.nix`) — answers split DNS for the half-public names,
  bound to the tailnet address on :53. See
  [split DNS](tailnet.md#split-dns-for-the-half-public-names).
- **Renovate** (`renovate.nix`) — a daily host timer, on the VPS rather than the
  CI runner so its cross-org write token never reaches an untrusted machine.
- **The Actions runner**, which is now a different machine entirely.
