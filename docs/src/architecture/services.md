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

| Service          | Exposure                                                                                                                                                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `caddy`          | 80/443 (+443/udp) for the public sites, and 8880/8443 for the tailnet-only ones — the second pair is kept private by its absence from the firewall's allow-lists, and nftables rewrites tailscale0's 80/443 onto it so those URLs carry no port. Built locally with the `caddy-ratelimit` module (`caddy.withPlugins`), not the stock image |
| `cloudflared`    | Tunnel connected, but **nothing routes through it** — `git`/`music`/`mail`/`smtp` are unproxied A records straight to the VPS, so caddy serves them directly                                                                                                                                                                                |
| `mailserver`     | SMTP/IMAP direct on 25, 465, 587, 993 — an MX must reach the host                                                                                                                                                                                                                                                                           |
| `webmail`        | roundcube, proxied at `mail.`                                                                                                                                                                                                                                                                                                               |
| `forgejo`        | **SSH on 22**, so clone URLs need no port; HTTP via caddy at `git.`; site admin (`/admin`, `/api/v1/admin`) tailnet-only                                                                                                                                                                                                                    |
| `navidrome`      | `127.0.0.1:4533`, reached only through caddy at `music.`                                                                                                                                                                                                                                                                                    |
| `kuma`           | proxy network only, reached at `status.`; the admin socket only on the tailnet copy of that name                                                                                                                                                                                                                                            |
| `searxng`        | proxy network only, reached at `search.`; the only public site behind `basic_auth`, with caddy `rate_limit` in front of the bcrypt                                                                                                                                                                                                          |
| `dozzle`         | `dozzle.` over the tailnet, and still 8080 directly — the direct port is deliberate, since this is what you open when caddy is the broken part                                                                                                                                                                                              |
| `grafana`        | host networking, :3000, tailnet only; also `grafana.`, which caddy reaches at the docker bridge address because host networking is invisible to docker's DNS                                                                                                                                                                                |
| `tempo`          | host networking, OTLP 4317/4318 bound to `0.0.0.0`; kept private by the firewall's input chain, not by the bind address                                                                                                                                                                                                                     |
| `minecraft`      | 25565; RCON on loopback only (25575). Heap 1 G floor / 6 G ceiling — see below                                                                                                                                                                                                                                                              |
| `minecraft2`     | second world, MC **1.21.1** on the `java21` image (world 1 is 26.1.2/java25) with its own mod list; 25566, reached via the `_minecraft._tcp.mc2` SRV record; RCON on loopback only (25576). Heap 1 G / 4 G                                                                                                                                  |
| `serenity-bot-0` | **nothing published**; an outbound Discord gateway client, on the `botnet` network. tokio-console on `127.0.0.1:6669`                                                                                                                                                                                                                       |
| `serenity-redis` | `botnet` only, no published port, no volume — a cache with a Discord fallback                                                                                                                                                                                                                                                               |
| `postgres`       | not a container — a host service; unix socket + loopback only, never on `botnet`                                                                                                                                                                                                                                                            |
| `pgbouncer`      | not a container — a host service; 6432, reachable from `botnet` and the tailnet, kept private by the firewall's input chain                                                                                                                                                                                                                 |
| `syncthing`      | not a container — a host service; GUI on 8384, tailnet only; also `syncthing.`, where caddy must rewrite the `Host` header or syncthing's rebinding check answers 403                                                                                                                                                                       |

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

Forgejo owns port 22, so **the host's sshd is on 2222**, and that is the way
in — Tailscale SSH is off. Keeping 22 is what lets git remotes stay portless:
ssh has no service discovery — it reads no `SRV` record — so anything else has
to be spelled out in every clone URL or every client's ssh config.

## caddy is built here, not pulled

caddy is the one container not pulled from a registry. It is built locally with
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
carry a digest as well:

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
`docker system prune` — **dangling layers only**, never a tagged or digest-
referenced image, and never a volume. The runner's podman prune is the one that
runs `--all`, and what that costs is covered in
[CI runner isolation](runner.md#the-garbage-collector-eats-it).

## Three things are deliberately not containers

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
- **The Actions runner**, which is now a different machine entirely.
