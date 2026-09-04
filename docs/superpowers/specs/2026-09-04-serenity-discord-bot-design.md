# serenity-discord-bot as a service

Design for adding [serenity-discord-bot](https://github.com/1Git2Clone/serenity-discord-bot)
to this host: a Rust Discord bot backed by PostgreSQL on bare metal behind
pgbouncer, built from upstream's own Dockerfile, and covered by a
`pg_dumpall`-based backup that generalises to every future database.

## Why the shape is what it is

The bot is an **outbound gateway client**. It opens a websocket to Discord and
serves nothing. So it gets no caddy vhost, no entry in `infra.certSubdomains`,
no proxy network, and no publicly published port. Three of the four things a new
service in this repo usually needs do not apply.

What it does need is three edges: PostgreSQL, Redis, and OTLP traces to tempo.
Grafana is **not** an edge — grafana reads tempo, the bot only writes to it.

## Topology

```
                    host netns                          botnet (172.30.0.0/24)
  postgres :5432 ──(unix socket)── pgbouncer ─┐
                                    :6432 ────┼── 172.30.0.1 ──┬── serenity-bot-0
  tempo :4317 (0.0.0.0, host net) ────────────┘                │        │
  grafana :3000 ── reads tempo, no bot edge                    └── serenity-redis:6379
```

A **pinned-subnet bridge network**, not `--network=host`. Host networking is one
line shorter and hands the bot every loopback service on the box — minecraft's
RCON on `127.0.0.1:25575`, forgejo on `4242`, navidrome on `4533`. Pinning the
subnet makes the gateway address deterministic, so `172.30.0.1` goes directly
into `DATABASE_URL` and `OTEL_EXPORTER_OTLP_ENDPOINT` with no `host-gateway`
indirection, and gives the firewall a subnet it can name. Redis is reached by
container name over docker's embedded DNS, the same way caddy reaches its
upstreams.

### `modules/containers/default.nix` needs generalising first

It currently hardcodes a single `docker-network-${net}` unit and wires
`after`/`requires` only for containers whose `networks` list contains `proxy`:

```nix
// lib.optionalAttrs (lib.elem net container.networks) { ... }
```

Adding a second network next to that special case would leave `serenity-bot-0`
starting with no dependency on its own network unit — a boot race that fails
intermittently, which is the worst shape. So the single unit becomes a
`mapAttrs'` over an attrset of network name → extra `docker network create`
flags, and the ordering `optionalAttrs` becomes an `intersectLists` against that
attrset's names. Same line count, one fewer special case.

## PostgreSQL and pgbouncer — new `modules/postgres.nix`

`services.postgresql` with `postgresql_18`. Upstream's compose runs
`postgres:18.3` and nixpkgs has 18.6 — same major, so dumps interchange.
`ensureDatabases` and `ensureUsers` with `ensureDBOwnership = true` give the
declarative half.

Postgres itself stays on the unix socket plus loopback: `enableTCPIP` is left at
its default `false`, which resolves `listen_addresses` to `localhost`. pgbouncer
is the only thing the bridge can reach, so there is one listener to reason
about rather than two.

### The role password needs an idempotent `ALTER ROLE`

`ensureUsers` creates a role with **no** password, and
`ensureUsers.*.passwordFile` does not exist in nixpkgs 26.05 — it was deprecated
and removed. `initialScript` is not a substitute: it runs only at first
`initdb`, so it would silently not apply to a cluster that already exists, which
is precisely the situation after the one-time dump restore.

So a `Type = "oneshot"` unit ordered after `postgresql.service` sets it on every
activation:

```sh
psql -v pw="$(cat ${passwordFile})" -c "ALTER ROLE serenity WITH PASSWORD :'pw';"
```

`:'pw'` is psql's quoted-variable interpolation, which escapes the value as a
SQL literal. Interpolating the password into the SQL string in shell instead
would break on any password containing a quote, so this is not a stylistic
choice.

`password_encryption` is set to `scram-sha-256` explicitly. Postgres 18 already
defaults to it, but it determines what `ALTER ROLE` stores, and pgbouncer's
`auth_type` has to agree — a silent default change here would break
authentication at some later upgrade rather than at the edit that caused it.

`services.postgresql.authentication` gains one line for the socket path. The
module documents that added rules are inserted **above** its defaults, so it
lands ahead of the generated `local all all peer`.

### pgbouncer runs in transaction mode

`pool_mode = "transaction"`, `listen_port = 6432`, and `max_prepared_statements`
set **explicitly**.

That last setting is the whole reason transaction mode is viable here. sqlx 0.9
keeps a 100-entry prepared-statement cache per connection; transaction pooling
hands the server connection back at commit, so a cached `sqlx_s_N` disappears
from under the client and the next use fails with
`prepared statement "sqlx_s_7" does not exist`. pgbouncer 1.25.2 (what nixpkgs
26.05 carries) tracks named prepared statements and re-prepares them on whichever
backend it assigns, making this transparent. It has defaulted to 200 since 1.24,
so this pins a value that currently works — the failure mode if the default ever
moves back is intermittent and load-dependent, not a startup error.

### Two traps in the pgbouncer module

**Its config goes into the Nix store.** The module does
`environment.etc.${configPath}.source = configFile`, so anything inline in
`settings` is world-readable — exactly what `modules/options.nix` warns about.
`auth_file` therefore points at a sops-rendered path holding
`"serenity" "<password>"`, owned by `pgbouncer` at `0400`. pgbouncer derives
SCRAM for both the client leg and the server leg from that plaintext, so one
credential serves both.

**`openFirewall` would do nothing.** It writes to
`networking.firewall.allowedTCPPorts`, which lands in the `nixos-fw` table that
this repo's `networking.nftables.ruleset` explicitly deletes and redefines. It
would evaluate cleanly and open no port. Left off; the rule goes in the
hand-written ruleset like every other port here.

### `listen_addr = "*"`, kept private by the firewall

The tempting choice is `listen_addr = "172.30.0.1"` — bind only to the bridge.
That reintroduces the bug `modules/containers/tempo.nix` documents: a specific
bind address that does not exist yet fails with *cannot assign requested
address*, and the docker bridge is created by a unit pgbouncer would then have to
be ordered against. Binding `*` and letting the input chain be the boundary is
the posture this repo already takes for tempo's 4317/4318 and grafana's 3000, and
it removes the ordering dependency entirely.

The consequence, stated rather than discovered: the input chain accepts
`iifname tailscale0` wholesale, so pgbouncer on 6432 is reachable from the
tailnet with a password. Same posture as grafana, and it is what makes the
one-time migration verifiable with `psql` from a laptop.

## Build and run — new `modules/containers/serenity-bot.nix`

Upstream publishes no image, so it gets built on the host.

```nix
src = pkgs.fetchgit { url = "…/serenity-discord-bot"; rev = "1bdde3a6…"; hash = "sha256-…"; };
tag = "serenity-discord-bot:${builtins.substring 0 12 rev}";
```

A `Type = "oneshot"`, `RemainAfterExit = true` unit `serenity-bot-image`,
`requiredBy` and `before` every bot container, guarding on the tag:

```sh
docker image inspect ${tag} >/dev/null 2>&1 && exit 0
docker build --build-arg RUSTFLAGS='…' --build-arg FEATURES='…' -t ${tag} ${src}
```

The rev is *in the tag*, so bumping `rev` changes the image string, which changes
the container unit, which is what makes systemd recreate the container. This is
the same store-path-changes-recreate-the-container mechanism
`modules/containers/default.nix` already relies on for config files. An unchanged
rev makes the unit `exit 0`, so a routine redeploy does not spend twenty minutes
rebuilding Rust.

`pull = "never"` on the containers. The default `"missing"` would also work — it
finds the local tag — but `never` makes a missing image fail with a clear error
instead of attempting a registry lookup for a tag that exists nowhere and
reporting whatever the registry says about it.

Source arrives hash-pinned via `fetchgit` while the build stays upstream's own
two-stage Dockerfile, so their build knowledge is not duplicated in Nix.
`build.rs` is only a `cargo:rerun-if-changed`, so `leaveDotGit = false` is fine.
No `--pull`: upstream's `debian:bullseye-slim` runtime base is a moving tag, and
not refreshing it keeps rebuilds stable.

### `RUSTFLAGS` must be passed explicitly

`.cargo/config.toml` in the bot repo sets
`rustflags = ["--cfg", "tokio_unstable"]`, but the Dockerfile does
`ARG RUSTFLAGS=""` followed by `ENV RUSTFLAGS=${RUSTFLAGS}` — and cargo lets a
**set-but-empty** `RUSTFLAGS` override `build.rustflags` from the config file
entirely. Taking the default therefore drops `--cfg tokio_unstable` and the
`tokio_console` feature fails to compile. Hence
`--build-arg RUSTFLAGS='--cfg tokio_unstable'`, which is also why upstream's own
compose file passes it.

`FEATURES = "ai-deepseek opentelemetry tokio_console"`.

### Container hardening

The `dozzle`/`tempo` baseline — `--read-only`,
`--security-opt=no-new-privileges:true`, `--cap-drop=ALL`, `--tmpfs=/tmp` —
plus `HOME=/tmp`. `ai-deepseek` pulls in `/ai-review`, which shells out to `git`
and `gh` (upstream's Dockerfile installs both for exactly this reason) and needs
writable scratch. This is the one item to verify after first deploy rather than
assume; if `/ai-review` turns out to need more than `/tmp`, the fix is a larger
tmpfs, not dropping `--read-only`.

`tokio_console` gets `TOKIO_CONSOLE_BIND=0.0.0.0:6669` and a host-loopback
publish. Without the bind override the console listens on container loopback and
is unreachable — a build feature paid for and inert. Loopback-only publish is the
minecraft-RCON pattern already in this repo.

Redis is `redis:8-alpine`, botnet only, no published port, and **no volume**. It
is a cache with a documented Discord fallback, so persisting it buys nothing and
would add a junk entry under `/var/lib/docker/volumes` that restic then carries
forever.

## Sharding

Two values at the top of the module, and only the first is meant to be touched:

```nix
shards = 1;      # ← Discord-facing shard count. The one line.
instances = 1;   # processes to spread them across.
```

Ranges are computed, never written down:

```nix
per = builtins.div shards instances;
rem = shards - per * instances;
# instance i takes `per` shards, plus one more while i < rem
start = i * per + (lib.min i rem);
end   = start + per + (if i < rem then 1 else 0) - 1;
```

`shards = 5; instances = 2` gives `0..=2` and `3..=4`. `assertions` cover
`shards >= 1`, `instances >= 1`, and `instances <= shards`. Changing `shards` to
8 and redeploying yields eight shards with no range arithmetic anywhere in the
config — which is the point, since upstream's `deploy/supervisor/` hardcodes two
instances with literal ranges and that is the part not worth copying.

These are plain `let` bindings rather than `infra.*` options: nothing outside
this module reads them, and `modules/options.nix` is explicitly for values more
than one module needs.

**`instances` defaults to 1 on purpose.** Serenity's `start_shard_range` runs
multiple shards *inside one process*, sharing one cache and one connection pool.
On a single host that beats N processes on memory and on log legibility.
`instances` only earns its keep for multi-host or blue-green, which is what
upstream uses it for.

**The degenerate case takes the old code path.** At `shards = 1; instances = 1`
the module emits no shard variables at all, so `src/main.rs:253` falls to the
`else` branch — `client.start()`, the single-shard path that has been running in
production. Only `shards > 1` or `instances > 1` sets the triple. This matters
because the explicit path leans on a quirk: `main.rs:252` passes Rust's exclusive
`start..end` and relies on serenity treating `range.end` as *inclusive*. That is
upstream's documented intent and they run it, but there is no reason to route the
default deploy through it.

**Container names are always indexed** — `serenity-bot-0`, `serenity-bot-1`.
Naming it plain `serenity-bot` when `instances = 1` would make the unit name
shift under a config change, and that name is what gets typed into
`journalctl -u docker-…` and written into `docs/deploying.md`.

**`tokio_console` needs a port per instance**: `127.0.0.1:${6669 + i}:6669`.
Two instances would otherwise collide on the host port and the second container
would fail to start.

Resharding costs one gateway IDENTIFY per shard, rate-limited by the
`max_concurrency` Discord issues (1 for a bot this size). The blip therefore
scales: eight shards is roughly a 40-second staggered reconnect, not instant.

At `instances > 1`, Redis stops being optional — the AI locks and rate limits are
per-process without it. It is already in the design; this is only the reason it
becomes load-bearing.

## Firewall — `modules/firewall.nix`

One rule, in the **input** chain:

```
iifname "br-*" ip saddr 172.30.0.0/24 tcp dport { 6432, 4317 } ct state new accept
```

Input, not forward: container-to-host traffic is destined for the host itself, so
it hits the input hook. Nothing is added to the public input or forward port
lists, because nothing is published to the internet. Forward already has
`iifname "br-*" accept`, so the bot's egress to Discord and DeepSeek works
unchanged.

Without this rule the failure is the shape `modules/firewall.nix` already warns
about twice: postgres healthy, pgbouncer healthy, `systemctl` clean, and the bot
unable to connect.

## Backups

```nix
services.postgresqlBackup = {
  enable = true;            # databases = [] ⇒ backupAll ⇒ pg_dumpall
  startAt = "*-*-* 23:15:00";
  compression = "zstd";
};
```

Plus one line in `modules/backups.nix` adding `/var/backup/postgresql` to the
restic `paths`.

This is the declarative property that was wanted. Leaving `databases` at its
default `[]` flips `backupAll`, which runs **`pg_dumpall`** — so it covers every
database on the host including ones added years from now. A future service is
backed up the moment it declares a database, which is the same "nothing to
remember to add to a path list" invariant the `/var/lib/docker/volumes` comment
in `modules/containers/default.nix` exists to defend. No
`/var/lib/dumps/<service>/dump.sql`, no per-service wiring, no imperative script.

`pg_dumpall` also emits **globals** — roles and their SCRAM verifiers — so a
restore brings the accounts back with the data. That is the "with its environment
data" half of the requirement; the other half is already in git as encrypted
`secrets.yaml`.

It also closes a hole the bare-metal move would otherwise open: `/var/lib/postgresql`
is **not** under `/var/lib/docker/volumes`, so restic would have quietly stopped
covering this service's data. And a file-level copy of a live `PGDATA` is not
restore-safe regardless, so dumps are the correct artifact here rather than a
compromise.

Restore is `zstd -d < all.sql.zst | psql -U postgres`.

### 23:15 is load-bearing

`services.restic.backups.b2` is `OnCalendar = "daily"` with
`RandomizedDelaySec = "1h"`, so it fires somewhere in 00:00–01:00. The stock
`postgresqlBackup` time of 01:15 is **after** that window, which would have
restic archiving a dump up to 23 hours stale every night, with both units
reporting success. This gets a comment in both files.

An independent timer is deliberately chosen over hanging the dump off restic's
`backupPrepareCommand`. That runs as `ExecStartPre`, so a transient
`pg_dumpall` failure would abort the entire nightly backup of every other
service on the host. Separate failure domains are worth the scheduling comment.

## One-time migration of `~/serenity-bot-db.sql`

Ordering gets one shot. The bot runs its sqlx migrations automatically at
startup, so if it reaches an empty database first, its migrations create the
schema and the dump's `CREATE TABLE`s then collide. The container comes up
**after** the restore.

Two properties of the dump have to be read off the box first, because both change
the commands:

1. `pg_dump` (needs a target database) versus `pg_dumpall` (carries its own
   `CREATE DATABASE` and `\connect`).
2. The **owner role name** it was dumped under. A plain-SQL dump emits
   `ALTER TABLE … OWNER TO <role>`, which hard-fails under
   `psql -v ON_ERROR_STOP=1` if that role does not exist. The cheap fix is to
   name the NixOS role to match the dump rather than rewrite the dump — so the
   dump decides `ensureUsers`, not this document.

Verification is `journalctl -u docker-serenity-bot-0` reporting migrations as
already applied rather than running them.

## Files

| File | Change |
|---|---|
| `modules/postgres.nix` | **new** — postgres, role password unit, pgbouncer, postgresqlBackup |
| `modules/containers/serenity-bot.nix` | **new** — fetchgit, build unit, bot instances, redis |
| `modules/containers/default.nix` | generalise the network unit to an attrset; fix start-ordering to cover both networks |
| `modules/options.nix` | `infra.botNetwork`, `infra.botSubnet`, `infra.botGateway` |
| `modules/firewall.nix` | one input rule |
| `modules/backups.nix` | one restic path plus the scheduling comment |
| `configuration.nix` | import `./modules/postgres.nix` |
| `secrets.yaml` | three values, added with `sops` |
| `docs/deploying.md` | secret count 17 → 20 (two places), container health-check list |
| `README.md` | service table, secrets inventory, backup section |

### Secrets

Three, following the observable `<service>_<thing>` naming with an explicit
nested `key`:

| Nix name | `secrets.yaml` key |
|---|---|
| `serenity_bot_token` | `serenity/bot_token` |
| `serenity_ai_api_key` | `serenity/ai_api_key` |
| `serenity_db_password` | `serenity/db_password` |

Plus a sops **template** for the pgbouncer userlist, built from the
`serenity_db_password` placeholder — a template rather than a fourth secret so
the password has one source of truth.

`serenity_db_password` is declared in `modules/postgres.nix` (it owns the
database identity) and the other two in `modules/containers/serenity-bot.nix`,
each next to what reads it. A global hook blocks reading `modules/secrets.nix`,
so its conventions could not be matched directly; moving all three there later is
mechanical.

sops-nix validates at activation, not evaluation, so `nixos-rebuild` evaluates
cleanly before the values exist and fails at activation until they are added.

## Out of scope

- **Autosharding.** `src/main.rs` never calls serenity's `start_autosharded()`;
  it has only the explicit-range path and `client.start()`. Adding it is an
  upstream change, not configuration.
- **Blue-green rollout.** Upstream drives it with supervisor and
  `scripts/bg-deploy.sh`. A redeploy blip is acceptable here.
- **`util-download`** (`yt-dlp`/`ffmpeg` on PATH) is not in the feature set, so
  its runtime dependencies are not installed.
- **Caddy, TLS, DNS.** The bot serves nothing.
