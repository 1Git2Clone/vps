# Provisioning a machine

Installing NixOS onto hardware that has none, and the maintenance that
only comes up around an install: restoring data into a fresh service, and
growing the disk after a resize.

For updating a machine that already runs NixOS, see [Deploying](deploying.md).

---

## Bare metal — a brand new server

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
