# Runbook

Commands, in the order you are likely to want them. Everything here runs on the
VPS over ssh on port 2222 (`ssh -p 2222 hutao@vps`); the runner's equivalents
are at the bottom, and they are reached differently.

## Is anything broken

```sh
systemctl --failed
systemctl list-units 'docker-*'
journalctl -u docker-forgejo -f           # every container logs to the journal
```

## Everything else

```sh
systemctl list-units 'docker-*'
journalctl -u docker-forgejo -f           # every container logs to the journal

systemctl status acme-renew-hu-tao.dev.timer  # renews well before expiry; a no-op most days
systemctl start acme-hu-tao.dev.service   # force a renewal check

systemctl status restic-backups-b2.timer restic-backups-minecraft.timer
restic-b2 snapshots                       # wrapper with the repo and password wired in

systemctl status postgresqlBackup.timer   # 23:15, deliberately BEFORE restic's 00:00-01:00 window
systemctl start postgresqlBackup          # dump every database now
psql -h 127.0.0.1 -p 6432 -U serenity serenity_bot   # through pgbouncer, from the tailnet

fail2ban-client status forgejo-ssh
nft list table inet f2b-table             # where the bans actually are
nft list table inet nixos-fw

tailscale status                          # peers, and this node's own address
tailscale whois 100.109.115.12            # THIS node: `Tags: tag:vps` or the ACL does not apply

systemctl status image-archive.timer      # 23:30, ahead of restic's 00:00-01:00 window
systemctl start image-archive             # docker save every pullable image now
ls -la /var/lib/image-archive             # one .tar + one .id per image
```

## When an image cannot be pulled

Nothing to do — every pullable container's unit runs `ensure-image` before it
starts, which tries the local image, then a pull, then the nightly archive,
then restic. `journalctl -u docker-<name>` names whichever step it reached.

The recovery path can be exercised by hand without touching a running service:

```sh
restic-b2 restore latest --path /var/lib/image-archive \
  --include /var/lib/image-archive/<slug>.tar --target /tmp/rt
```

`--path` is not optional: this repository also holds the weekly minecraft
snapshots, and a bare `latest` can name one of those, which carries no archive.
`--target /` is what `ensure-image` uses, because restic recreates the absolute
path under the target. The slug is the image reference with `/`, `:` and `@`
each replaced by `_`. Verified end to end on 2026-09-21.

The weekly minecraft job stops both worlds' servers, snapshots, and starts
them again from `ExecStopPost` — so they come back whether restic succeeded or
not. A live world is not consistent on disk: the server holds region files open
and writes them in place, which is why the daily backup excludes that volume and
this job exists.

## On the runner

The runner is off the tailnet on purpose, so every command goes through the VPS:

```sh
ssh -J vps root@46.225.61.172

systemctl status gitea-runner-forgejo
journalctl -u gitea-runner-forgejo -f     # a job that never starts shows here
journalctl -u forgejo-runner-identity     # the uuid/secret compose step

podman ps                                 # job containers, one per running job
podman images                             # localhost/forgejo-ci-nix-node must be here
systemctl restart forgejo-runner-ci-image # reload it if the prune ate it
du -sh /var/lib/forgejo-runner/cache      # the Actions cache
nft list table inet nixos-fw              # the one-way rules; counters included
```

`nft list counters` is the quick check that the one-way rule is doing something:
`vps_allowed_out` should climb while jobs run, and `vps_blocked_out` should stay
where it was. See [CI runner isolation](../architecture/runner.md#the-one-way-rule-and-how-it-is-enforced).

The ingress pair answers the other direction — `ssh_from_vps` climbs every time
you open the jump above, and `ssh_blocked` is anyone else trying:

```sh
ssh -J vps root@46.225.61.172 nft list counter inet nixos-fw ssh_from_vps
ssh -J vps root@46.225.61.172 nft list counter inet nixos-fw ssh_blocked
```
