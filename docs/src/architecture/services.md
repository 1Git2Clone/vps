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
| `forgejo`        | **SSH on 22**, so clone URLs need no port; HTTP via caddy at `git.`                                                                                                                                                                                                                                                                         |
| `navidrome`      | `127.0.0.1:4533`, reached only through caddy at `music.`                                                                                                                                                                                                                                                                                    |
| `kuma`           | proxy network only, reached at `status.`                                                                                                                                                                                                                                                                                                    |
| `searxng`        | proxy network only, reached at `search.`; the only public site behind `basic_auth`, with caddy `rate_limit` in front of the bcrypt                                                                                                                                                                                                          |
| `dozzle`         | `dozzle.` over the tailnet, and still 8080 directly — the direct port is deliberate, since this is what you open when caddy is the broken part                                                                                                                                                                                              |
| `grafana`        | host networking, :3000, tailnet only; also `grafana.`, which caddy reaches at the docker bridge address because host networking is invisible to docker's DNS                                                                                                                                                                                |
| `tempo`          | host networking, OTLP 4317/4318 bound to `0.0.0.0`; kept private by the firewall's input chain, not by the bind address                                                                                                                                                                                                                     |
| `minecraft`      | 25565; RCON on loopback only (25575)                                                                                                                                                                                                                                                                                                        |
| `minecraft2`     | second world, MC **1.21.1** on the `java21` image (world 1 is 26.1.2/java25) with its own mod list; 25566, reached via the `_minecraft._tcp.mc2` SRV record; RCON on loopback only (25576)                                                                                                                                                  |
| `serenity-bot-0` | **nothing published**; an outbound Discord gateway client, on the `botnet` network. tokio-console on `127.0.0.1:6669`                                                                                                                                                                                                                       |
| `serenity-redis` | `botnet` only, no published port, no volume — a cache with a Discord fallback                                                                                                                                                                                                                                                               |
| `postgres`       | not a container — a host service; unix socket + loopback only, never on `botnet`                                                                                                                                                                                                                                                            |
| `pgbouncer`      | not a container — a host service; 6432, reachable from `botnet` and the tailnet, kept private by the firewall's input chain                                                                                                                                                                                                                 |
| `syncthing`      | not a container — a host service; GUI on 8384, tailnet only; also `syncthing.`, where caddy must rewrite the `Host` header or syncthing's rebinding check answers 403                                                                                                                                                                       |

The Forgejo Actions runner is **not on this list any more**: it lives on its
own machine. See [CI runner isolation](runner.md).

Forgejo owns port 22, so **the host's sshd is on 2222** and normal access is
over Tailscale SSH. Keeping 22 is what lets git remotes stay portless: ssh has
no service discovery — it reads no `SRV` record — so anything else has to be
spelled out in every clone URL or every client's ssh config.

## caddy is built here, not pulled

caddy is the one container not pulled from a registry. It is built locally with
the `caddy-ratelimit` module compiled in (`caddy.withPlugins`, wrapped in a
minimal `dockerTools` image), because stock caddy has no rate limiting — and
rate limiting is load-bearing for `search.`, see
[Access control](access-control.md).

It is still caddy 2.11.4 — the version tracks nixpkgs, which matches the tag
the official image used — and keeps the full container hardening: non-root uid
from `ids.nix`, read-only rootfs, `--cap-drop=ALL`, and tmpfs for `/data`,
`/config` and `/tmp`.

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
