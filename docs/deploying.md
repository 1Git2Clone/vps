# Deploying

Three paths, in order of how often you'll walk them: **redeploy** (constantly),
**first deploy** (once per machine), **bare metal** (once, or after a disaster).

Everything below assumes the ssh key is loaded, because it is passphrase-
protected and nothing here can prompt for it:

```sh
ssh-agent -a /tmp/hutao-agent.sock >/dev/null 2>&1
SSH_AUTH_SOCK=/tmp/hutao-agent.sock ssh-add ~/.ssh/id_ed25519
export SSH_AUTH_SOCK=/tmp/hutao-agent.sock
```

A `Permission denied (publickey)` from any command here almost always means the
agent is gone, not that a key is missing on a server.

---

## 1. Redeploy — the everyday path

```sh
nix flake check          # optional; deploy builds anyway
deploy .#vps
```

Without deploy-rs — same result, no automatic rollback:

```sh
nix develop            # provides nixos-rebuild on a non-NixOS workstation
nixos-rebuild switch --flake .#vps-hetzner --target-host hutao@vps --use-remote-sudo
```

See "If deploy-rs ever disappears" in the README: an unresolvable flake input
stops the flake evaluating at all, so that fallback needs the input removed
first, not just a different command.

That is the whole thing. `deploy-rs` builds locally, pushes the closure,
activates it, then **waits for a fresh connection to confirm the box is still
reachable**. If it cannot reconnect, the machine rolls itself back to the
previous generation without being asked.

What it protects and what it does not:

| Failure                                           | Caught by                                |
| ------------------------------------------------- | ---------------------------------------- |
| firewall / sshd / networking change locks you out | **deploy-rs auto-rollback**              |
| unbootable kernel or initrd                       | GRUB generation menu, 5s timeout at boot |
| a container fails to start                        | _not_ auto-rolled back — see below       |

The last row is deliberate. deploy-rs confirms reachability, not service health.
A crashlooping container is visible and you still have ssh, so:

```sh
ssh -p 2222 hutao@hu-tao 'systemctl --failed; systemctl status docker-<name>'
ssh -p 2222 hutao@hu-tao 'sudo nixos-rebuild switch --rollback'
```

Rolling the whole system back because one container is unhappy is usually the
wrong reflex — fix it forward.

### Ports and names, so nothing surprises you

- `hu-tao` is the **MagicDNS name**, which is why `deploy.nodes.vps.hostname` is
  a name and not an address. It survives the primary-IP handover during a
  migration, so the same command works before and after cutover.
- ssh is on **2222**. Port 22 belongs to forgejo, so that git clone URLs need no
  port. Going through Tailscale SSH instead would hit its interactive re-auth
  check, which cannot be scripted — hence port 2222 and a normal key.

### If a deploy fails with "lacks a signature by a trusted key"

`nix.settings.trusted-users` must include `@wheel` (it does, in
`modules/nix.nix`). If you ever deploy to a machine that predates that setting,
you cannot push to it — build on the box instead:

```sh
rsync -a --delete --exclude .git -e 'ssh -p 2222' ./ hutao@hu-tao:nixos-image/
ssh -p 2222 hutao@hu-tao 'cd nixos-image && sudo nixos-rebuild switch --flake .#vps-hetzner'
```

That is also the bootstrap for the very first deploy after an install.

---

## 2. First deploy to a machine that already runs NixOS

Same as a redeploy, with two one-time steps:

```sh
# 1. Trust the host key, or deploy-rs fails with "Host key verification failed"
#    and no way to answer the prompt.
ssh-keyscan -p 2222 -H hu-tao >> ~/.ssh/known_hosts

# 2. Confirm the box can decrypt its own secrets before relying on it.
ssh -p 2222 hutao@hu-tao 'sudo ls /run/secrets/ | wc -l'   # expect 20
```

Then `deploy .#vps`.

---

## 3. Bare metal — a brand new server

This is meant to be close to one command. It is, **provided the machine's
quirks are already in the config** — see "What makes this automatic" below.

```sh
cd tofu
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
tofu init
tofu plan          # READ IT. Abort on any "destroy and then create" of hcloud_server.
tofu apply
```

`tofu` creates the server with your ssh key attached at creation. It does **not**
install NixOS — that is deliberate. Run the install separately:

```sh
nix run .#install -- root@$(tofu -chdir=tofu output -raw vps_ipv4)
```

tofu used to own the install through nixos-anywhere's module. That was removed:
the module declares a `null_resource` whose _creation_ runs a full install, so
any plan made without it already in state — a fresh clone, a lost state file, a
`state rm` — quietly proposes reinstalling a running mail server. Infrastructure
and OS installation are now separate on purpose.

### Installing onto a server that already exists

One command:

```sh
nix run .#install -- root@<ip>
```

It verifies the age key decrypts `secrets.yaml` **before** starting, stages it
into a temporary extra-files tree at 0600, and selects `vps-hetzner`. Extra
arguments are passed through to nixos-anywhere (`--debug`, `--build-on-remote`).

Equivalent by hand, if you ever need to vary it:

```sh
mkdir -p /tmp/extra/var/lib/sops-nix
install -m 0600 ~/.sops-nix/key.txt /tmp/extra/var/lib/sops-nix/key.txt

nix run github:nix-community/nixos-anywhere -- \
  --flake .#vps-hetzner \
  --target-host root@<ip> \
  --extra-files /tmp/extra
```

**`--extra-files` is not optional.** Without the age key at
`/var/lib/sops-nix/key.txt`, `sops-install-secrets` fails during activation and
the machine boots with no credentials at all — including its own root and user
passwords. Check the key decrypts _before_ installing:

```sh
SOPS_AGE_KEY_FILE=~/.sops-nix/key.txt sops -d --extract '["email"]["postmaster"]' secrets.yaml
```

If the target only accepts a key you do not hold, Hetzner rescue mode is the way
in — `enable_rescue` accepts an `ssh_keys` list, unlike `rebuild`, which
re-injects whatever was attached at creation:

```sh
curl -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" -H 'Content-Type: application/json' \
  -d '{"type":"linux64","ssh_keys":[<key-id>]}' \
  https://api.hetzner.cloud/v1/servers/<id>/actions/enable_rescue
curl -X POST -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers/<id>/actions/reset
```

Rescue is a normal Linux with the disk unmounted, which is exactly what
nixos-anywhere wants.

### Which configuration to install

| Attr            | Disk       | Use                                     |
| --------------- | ---------- | --------------------------------------- |
| `.#vps`         | `/dev/vda` | the local QEMU VM (`nix run .#default`) |
| `.#vps-hetzner` | `/dev/sda` | **anything on Hetzner Cloud**           |

They are the same closure; only the disk device differs, and `boot.loader.grub.device`
is derived from disko so the two can never disagree. Installing `.#vps` on
Hetzner fails at disko because `/dev/vda` does not exist there.

---

## What makes this automatic (and what used to break it)

Every item below is now in the config. They are listed because each one, when
missing, produces a machine that installs with no error and then does not work —
the worst failure shape there is.

| Setting                                                 | Where                  | Without it                                                                                                                                                                         |
| ------------------------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `boot.initrd.availableKernelModules` with **virtio**    | `modules/hardware.nix` | NixOS's default set is bare-metal only. The initrd cannot see `/dev/sda`, root never mounts, and the box sits in an emergency shell while the provider still reports it `running`. |
| **GRUB**, not systemd-boot                              | `modules/boot.nix`     | Hetzner Cloud boots legacy BIOS — there is no `/sys/firmware/efi`. systemd-boot installs cleanly and leaves an unbootable machine.                                                 |
| `efiInstallAsRemovable`, `canTouchEfiVariables = false` | `modules/boot.nix`     | There is no efivarfs in BIOS mode; bootloader installation fails outright if it tries to write NVRAM.                                                                              |
| `time.timeZone`                                         | `modules/boot.nix`     | Unset means NixOS does not manage `/etc/localtime`, so docker creates a _directory_ there and every container that bind-mounts it dies with "not a directory".                     |
| `nix.settings.trusted-users = @wheel`                   | `modules/nix.nix`      | `deploy-rs` cannot push: "lacks a signature by a trusted key".                                                                                                                     |
| ssh on **2222**                                         | `modules/services.nix` | Port 22 is forgejo's. Also needs a matching rule in the **Hetzner edge firewall**, which is separate from the host's nftables.                                                     |

**The VM test cannot catch any of these.** `nixos-anywhere --flake .#vps
--vm-test` validates disko, GRUB and that the system boots — genuinely useful,
and it is what proved GRUB-on-BIOS works. But the NixOS test harness injects its
own virtio modules and its own networking, so a config that boots in the test can
still be unbootable on real hardware. Treat a passing VM test as "the layout and
bootloader are sane", never as "this will boot on the server".

---

## Restoring a postgres dump into a new service

`services.postgresqlBackup` writes a `pg_dumpall` to
`/var/backup/postgresql/all.sql.zstd` nightly, and restic carries it — so the
usual restore is one command:

```sh
zstd -d < /var/backup/postgresql/all.sql.zstd | sudo -u postgres psql
```

**Seeding a service from a dump made elsewhere is different, and the ordering
gets one shot.** The bot runs its sqlx migrations automatically on startup, so if
it reaches an empty database first, its migrations create the schema and the
dump's `CREATE TABLE`s then collide with it. Restore before the container's first
start.

Read the dump before running anything — two of its properties decide the
commands, and guessing either one wrong fails halfway through:

```sh
head -40 ~/serenity-bot-db.sql          # pg_dump (needs a target db) or pg_dumpall (has its own CREATE DATABASE)?
grep -m5 'OWNER TO' ~/serenity-bot-db.sql   # which role does it expect to exist?
```

A plain-SQL dump emits `ALTER TABLE … OWNER TO <role>`, which hard-fails under
`ON_ERROR_STOP=1` if that role is absent. The cheap fix is to make the config
match the dump — `role` and `db` at the top of `modules/postgres.nix` — rather
than to rewrite the dump.

Then, for a `pg_dump` of a single database:

```sh
sudo systemctl stop 'docker-serenity-bot-*'
sudo -u postgres psql -c 'DROP DATABASE IF EXISTS serenity_bot;'
sudo -u postgres psql -c 'CREATE DATABASE serenity_bot OWNER serenity;'
sudo -u postgres psql -v ON_ERROR_STOP=1 -d serenity_bot -f ~/serenity-bot-db.sql
sudo systemctl start docker-serenity-bot-0
```

`ON_ERROR_STOP=1` is not optional: without it `psql` reports success after
skipping every statement it could not apply, which leaves a half-populated
database that looks restored.

Confirm the bot treats the schema as current rather than migrating it:

```sh
journalctl -u docker-serenity-bot-0 -n 50
sudo -u postgres psql -d serenity_bot -c 'table _sqlx_migrations order by version desc limit 5;'
```

## Growing the disk after a Hetzner resize

Resizing the volume in the Hetzner console changes the block device and nothing
else. `disk-config.nix` declares root as `size = "100%"`, so a _fresh install_
fills the new disk correctly — but disko only partitions at install time, so a
running machine needs this once, by hand.

The symptom is that the space is invisible rather than merely unused:

```sh
lsblk -o NAME,SIZE            # sda 152.6G, but sda3 only 75.3G
sfdisk --list-free /dev/sda   # "Unpartitioned space: 0 B"  <- lying
```

`0 B` is the tell. GPT keeps a **backup header at the end of the disk**, so
after a resize the table still describes the old geometry — `last-lba` points at
the old final sector, and within that table the last partition genuinely does
fill the disk. `sfdisk` says so out loud if you read past the numbers:

```text
GPT PMBR size mismatch (160006143 != 320004095) will be corrected by write.
The backup GPT table is not on the end of the device.
```

Nothing can see the free space until that header moves. Neither `sgdisk` nor
`growpart` is in the system closure; pull them from the pinned nixpkgs rather
than adding them permanently for a once-per-machine job:

```sh
nix build --no-link --print-out-paths 'nixpkgs#gptfdisk^out'   # sgdisk
nix build --no-link --print-out-paths 'nixpkgs#cloud-utils'    # growpart
nix copy --to ssh://hutao@vps --no-check-sigs <both paths>
```

Take a backup first — `restic` runs daily, so force one if anything since the
last run matters, and save the partition table as the rollback artifact:

```sh
sudo systemctl start postgresqlBackup        # get the databases into the dump
sudo systemctl start restic-backups-b2       # then offsite
sfdisk -d /dev/sda | sudo tee /root/sda-parttable-$(date +%F).sfdisk
```

Then four steps, in this order:

```sh
sudo sgdisk -e /dev/sda      # 1. move the backup GPT to the true end of disk
sudo growpart /dev/sda 3     # 2. extend the LAST partition into the new space
sudo partx -u /dev/sda       # 3. make the running kernel re-read the table
sudo resize2fs /dev/sda3     # 4. grow ext4 online; safe while mounted
```

Step 1 is the one that is easy to skip and impossible to work around: without
it, step 2 finds no free space. Step 2 only changes the partition's _end_
offset, so no data moves — this works because root is the last partition. Step 4
needs the `resize_inode` feature, which is present.

Restore path if step 1 or 2 goes wrong: `sfdisk /dev/sda < /root/sda-parttable-*.sfdisk`,
from Hetzner rescue mode if the box will not boot.

### `e2fsck` will look alarming afterwards, and it is lying

```sh
sudo e2fsck -fn /dev/sda3
# ... ********** WARNING: Filesystem still has errors **********
```

**This is expected and is not evidence of damage.** e2fsck cannot meaningfully
check a mounted read-write filesystem: the kernel holds allocation state that
has not reached the on-disk bitmaps, and `-n` skips journal recovery. So it
reports bitmap differences, wrong free counts, and "deleted inode has zero
dtime" for files unlinked while still open. Declining every fix under `-n` is
what sets the error banner.

Prove it rather than worry about it — run it twice and compare:

```sh
sudo e2fsck -fn /dev/sda3 | grep "count wrong ("
sleep 20
sudo e2fsck -fn /dev/sda3 | grep "count wrong ("
```

Different numbers each run means it is tracking live writes. Identical numbers
would be the thing to investigate. What actually matters is
`tune2fs -l /dev/sda3 | grep "Filesystem state"` reporting `clean`.

A real check needs the filesystem offline: add `fsck.mode=force fsck.repair=yes`
to the kernel command line for one boot, or run it from rescue mode.

### Why not LVM

It would not have helped much _here_. Growing into new space would still need
the GPT header relocated and the partition extended before `pvresize`,
`lvextend`, `resize2fs` — three commands instead of two, for the same outcome.
Where it would pay is snapshots before a risky migration, and reallocating space
between volumes. Switching means a reinstall, since disko partitions only at
install time, so it belongs to the next bare-metal build rather than to a
resize.

## Verifying a machine is actually healthy

Not "the deploy said success" — these:

```sh
ssh -p 2222 hutao@hu-tao '
  systemctl is-system-running          # want: running
  systemctl --failed                   # want: empty
  sudo ls /run/secrets | wc -l         # want: 21
  sudo docker ps --format "{{.Names}} {{.Status}}"
  for u in caddy forgejo mailserver webmail kuma navidrome minecraft minecraft2 grafana tempo dozzle \
           cloudflared serenity-bot-0 serenity-redis; do
    echo "$u restarts=$(systemctl show -p NRestarts --value docker-$u)"
  done
  systemctl is-active postgresql pgbouncer serenity-bot-image'
```

Non-zero `NRestarts` means a crashloop that `systemctl is-active` will happily
report as `active`, because systemd restarts it fast enough to look healthy.

And confirm the certificate is real rather than the self-signed placeholder that
`security.acme` installs when issuance fails — services start either way, so
nothing looks wrong until you check the issuer:

```sh
ssh -p 2222 hutao@hu-tao 'sudo cat /var/lib/acme/hu-tao.dev/cert.pem' \
  | openssl x509 -noout -issuer -enddate
# want: issuer=C=US, O=Let's Encrypt, ...
# bad:  issuer=CN=minica root ca ...   <- placeholder, DNS-01 failed
```

Before triggering ACME, test the Cloudflare token directly — Let's Encrypt caps
failed validations at 5 per hour and lego spends one per attempt:

```sh
ssh -p 2222 hutao@hu-tao 'sudo bash -c "
  T=\$(cat /run/secrets/cloudflare_api_token)
  curl -sS -H \"Authorization: Bearer \$T\" \
    https://api.cloudflare.com/client/v4/zones?name=hu-tao.dev"'
```

An empty `result` array with `success: true` means the token cannot see the zone
— which reads as success if you only check `.success`.
