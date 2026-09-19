# CX33 → CX33 (→CX43) migration

Moving the stack from `ubuntu-4gb-fsn1-2` (server `137766340`, Ubuntu + Ansible)
to `ubuntu-8gb-fsn1-1` (server `163906050`, NixOS from this flake). Both in
**fsn1**, which is the fact the whole plan rests on: primary IPs are
location-bound, so `167.233.24.58` and its `smtp.hu-tao.dev` PTR can move
between these two machines. Nothing in DNS changes, SPF keeps naming the same
address, and sending reputation carries over intact.

Rescale to CX43 comes **after** the migration, and should be a type-only
upgrade — see `server_type` in `tofu/variables.tf` for why not to take the disk.

## Data mapping

The old box bind-mounts host directories; this config uses named docker volumes.
That makes the transfer a mapping, not an rsync of one tree. ~27 GB total.

| Source (old box)                       | Size     | Destination (new box)              | Entries   |
| -------------------------------------- | -------- | ---------------------------------- | --------- |
| `/srv/minecraft/data/`                 | 15 G     | volume `minecraft_data`            | 8107      |
| `~/syncthing/`                         | 11 G     | `~/syncthing/` (host path)         | —         |
| `/srv/forgejo/data/`                   | 271 M    | volume `forgejo_data`              | 1151      |
| `~/data/navidrome/`                    | 123 M    | volume `navidrome_data`            | 5020      |
| `/srv/mailserver/data/dms/mail-state/` | **95 M** | volume `dms_state`                 | —         |
| volume `grafana-data`                  | 50 M     | volume `grafana_data`              | —         |
| volume `tempo-data`                    | 16 M     | volume `tempo_data`                | —         |
| `/srv/kuma/data/`                      | 8.7 M    | volume `kuma_data`                 | 9         |
| `/srv/mailserver/data/dms/mail-data/`  | 2.5 M    | volume `dms_mail`                  | —         |
| `/srv/mailserver/data/roundcube/db/`   | 1.3 M    | volume `roundcube_db`              | —         |
| `/srv/mailserver/data/dms/config/`     | 12 K     | volume `dms_config`                | 1 account |
| `~/.config/syncthing/`                 | small    | `~/.config/syncthing/` (host path) | —         |

**Read these sizes as root.** Measured as `hutao`, `/srv/mailserver/data` reports
15 M; as root it is 110 M, because 24 paths under `/srv` are owned by container
uids (the mail store is uid 5000) and `find`/`du` silently skip what they cannot
read. A copy run as `hutao` therefore loses mail without erroring. Root over
Tailscale SSH is what makes the copy complete — `ssh root@<tailnet-ip>` works
even though `sudo` on that box demands a password.

`mail-state` is 95 M and is the bulk of the mail data. It is not scratch: it holds
dovecot's indexes and UIDVALIDITY, and rspamd's trained bayes database. Skip it
and every IMAP client re-downloads everything and your spam filter starts from
zero.

Deliberately **not** transferred:

| Skipped                                               | Why                                                                                                             |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `/srv/certbot/data`                                   | `security.acme` issues a fresh certificate; the certbot lineage layout is not the same and is not read any more |
| `/srv/dozzle/data`                                    | just `users.yml`, rendered from sops by `dozzle-users.service`                                                  |
| `/srv/caddy`, `caddy_caddy_*` volumes                 | ACME state caddy no longer manages                                                                              |
| `/srv/mailserver/data/dms/mail-logs`                  | 11 M of logs                                                                                                    |
| `roundcube/config`                                    | rendered from the Nix store                                                                                     |
| `postgres-data`, `serenity-discord-bot_postgres-data` | both 0 bytes, 0 links — dead volumes                                                                            |
| `deploy_*` volumes, `/srv/camofox-browser`            | expenses app and camofox, staying on the old box                                                                |
| docker build cache                                    | 3.8 G of nothing                                                                                                |

`~/.config/syncthing` carries the node's TLS keypair, which **is** its device ID.
Copy it and every paired device keeps working; regenerate it and you re-pair by
hand on every phone and laptop.

## The Discord bot's data

Not in a docker volume, which is why the two postgres volumes on the old box are
0 bytes: the bot talks to the **host's** PostgreSQL 18.6, listening on
`127.0.0.1:5432` and on the tailnet address. `DATABASE_URL` in the bot's `.env`
points at database `serenity_discord_bot`, 8.4 MB, 9 tables — and only
`user_stats` has rows (258 of them). Everything else is empty schema.

Dumped read-only with `pg_dump --no-owner --no-privileges`, and held in two
places so it does not live only on the box being retired:

```text
old box:     ~/migration-dumps/serenity-<timestamp>.sql
workstation: ~/migration-dumps/serenity-<timestamp>.sql
```

The bot itself stays on the old box for now. When it is ported, the NixOS side
needs `services.postgresql` (package 18 to match the source), the database
created, the dump restored, and `DATABASE_URL` plus the other 17 values from its
`.env` moved into sops. `--no-owner --no-privileges` is what lets the restore
land under a different role than the Ubuntu one that owns it today.

## The two Cloudflare tokens

There are two, with different jobs, and confusing them costs an hour:

| Where                                            | Used by                           | Token ID                           |
| ------------------------------------------------ | --------------------------------- | ---------------------------------- |
| `secrets.yaml` → `cloudflare.api_token`          | lego / `security.acme` on the VPS | `a13f8e29ba9ebe4201e5aef3d1723ec7` |
| `tofu/terraform.tfvars` → `cloudflare_api_token` | tofu, from a workstation          | `c91db61e8b430d39e780fd5e6098c225` |

The VPS token carries an **IP filter** pinned to the old server, so DNS-01 fails
from anywhere else with `403 9109: Cannot use the access token from location:
<ip>`. `security.acme` then falls back to a self-signed certificate and starts
dependent services anyway, so caddy and DMS come up serving a placeholder and
nothing looks broken until you check the issuer:

```sh
ssh -p 2222 hutao@<host> sudo cat /var/lib/acme/hu-tao.dev/cert.pem \
  | openssl x509 -noout -issuer
# issuer=CN=minica root ca …   <- placeholder
# issuer=C=US, O=Let's Encrypt …  <- real
```

Test the token directly rather than by triggering ACME — Let's Encrypt caps
failed validations at 5 per account per hostname per hour, and lego burns one
per attempt:

```sh
curl -sS -H "Authorization: Bearer $TOKEN" \
  'https://api.cloudflare.com/client/v4/zones?name=hu-tao.dev'
```

This resolves itself at cutover, when the box inherits the old server's address.

## Order of operations

Volumes must exist and be populated **before** their container first starts,
otherwise docker creates them empty and the service initialises itself blank —
forgejo would make a new instance, DMS an empty mail store. So: install, stop
the containers, load the data, start.

Observed on the freshly installed box, and both are the CORRECT empty-state
behaviour rather than faults to chase:

- **forgejo** serves HTTP 200 but `/api/v1/version` 404s and `repos: 0` — it
  is a blank instance that has not been through its install wizard. Restoring
  `forgejo_data` is what makes it the real instance; do NOT click through the
  wizard first, or you create a second one.
- **DMS loops** on `You need at least one mail account to start Dovecot (120s
left...)` and then exits, so systemd restarts it. Accounts live in
  `postfix-accounts.cf` inside the `dms_config` volume. Until that volume is
  restored there is no account, and DMS refuses to run Dovecot or Postfix —
  which is why ports 25/465/587/993 have no banner yet. Restoring `dms_config`
  resolves it; nothing needs fixing.

```sh
export SSH_AUTH_SOCK=/tmp/hutao-agent.sock   # key is passphrase-protected
NEW=178.105.223.159
```

### 1. Install NixOS

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#vps-hetzner \
  --target-host root@$NEW \
  --extra-files <staged age key dir>
```

`vps-hetzner`, not `vps`: it targets `/dev/sda`. The extra-files directory
carries `/var/lib/sops-nix/key.txt` at 0600 — without it the host boots unable
to decrypt anything, including its own root password.

### 2. Quiesce, then load data

```sh
ssh -p 2222 hutao@$NEW 'sudo systemctl stop "docker-*"'
```

Old box first, so nothing is written mid-copy:

```sh
ssh hutao@100.97.90.108 'sudo systemctl stop docker-services; \
  cd /srv && for d in forgejo mailserver minecraft kuma navidrome; do \
    (cd $d 2>/dev/null && sudo docker compose down); done'
```

Then, from the OLD box over the tailnet (traffic stays inside fsn1 rather than
going via a workstation), for each row of the mapping:

```sh
sudo rsync -aHAX --numeric-ids --info=progress2 \
  /srv/forgejo/data/ root@hu-tao:/var/lib/docker/volumes/forgejo_data/_data/
```

`-aHAX --numeric-ids` because uid/gid must survive verbatim: forgejo's repos,
the mail store and grafana's data are owned by container uids that mean nothing
in either host's `/etc/passwd`.

Create each volume before writing into it:

```sh
ssh -p 2222 hutao@$NEW 'for v in forgejo_data dms_mail dms_state dms_config \
  roundcube_db minecraft_data kuma_data navidrome_data grafana_data tempo_data; \
  do sudo docker volume create $v; done'
```

### 3. Verify before cutover

DNS-01 works regardless of which IP the box holds, so certificates can be
issued and the whole stack tested while the old box is still live.

```sh
ssh -p 2222 hutao@$NEW 'systemctl start docker-network-proxy; sudo systemctl start "docker-*"'
ssh -p 2222 hutao@$NEW 'systemctl is-system-running; systemctl --failed'
curl --resolve git.hu-tao.dev:443:$NEW https://git.hu-tao.dev/api/v1/version
curl --resolve status.hu-tao.dev:443:$NEW https://status.hu-tao.dev/api/entry-page
```

Check `journalctl -u docker-mailserver` shows the certificate loading from
`/certs`, and that forgejo lists the migrated repositories.

### 4. Cutover — the IP handover

Hetzner requires a server to be **powered off** to (un)assign a primary IP.

1. Final delta rsync of the mapping rows (minutes, since only deltas move)
2. Power off both servers
3. Unassign `147045244` (`178.105.223.159`) from `163906050`
4. Unassign `134632948` (`167.233.24.58`) from `137766340`
5. Assign `134632948` to `163906050`
6. Assign `147045244` to `137766340` — the old box stays online at the other
   address, so serenity-bot, camofox and the expenses app keep running
7. Power on both

`smtp.hu-tao.dev` follows `134632948` automatically; it is a property of the IP.

### 5. Rollback

Steps 2–7 in reverse. The old box is untouched, still holds its data, and has
`delete` and `rebuild` protection on. Rollback is ~5 minutes and costs nothing
but the swap.

## After it settles

- Attach firewall `11483636` to `163906050` (currently attached only to the
  old box)
- Enable `delete` + `rebuild` protection on `163906050`
- Import into tofu: server, primary IPs, firewall, rDNS, and the 11 Cloudflare
  records. **Read the plan** — abort if it shows `destroy and then create` on
  `hcloud_server`
- Empty `legacy_server_ids` in `tofu/variables.tf` only once the old box is retired;
  it is what keeps the edge firewall attached to it
- Port serenity-bot properly (Rust + sqlx, needs a Nix build, `services.postgresql`
  with the dump restored, and its `.env` in sops)
- From then on deploys are `deploy .#vps` — auto-rollback on lockout

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
  certificate is _named_ `hu-tao.dev` with the subdomains as SANs, so reordering
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
  purpose — see the fail2ban row in [Failure modes](../operations/recovery.md#the-fail2ban-blast-radius)
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
