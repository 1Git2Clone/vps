# Runbook

Commands, in the order you are likely to want them. Everything here runs on the
VPS over Tailscale SSH; the runner's equivalents are at the bottom, and they are
reached differently.

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

systemctl status vuln-scan.timer          # Saturdays 06:00 UTC
systemctl start vuln-scan                 # run one now — it posts to Discord
journalctl -u vuln-scan -n 50
```

The vulnerability scan covers every image declared in
`virtualisation.oci-containers` — running or not, so a stopped container is still
scanned — plus the NixOS system closure, which is what covers tailscale, sshd,
docker and the kernel. It posts at most two Discord messages and attaches the
complete report as a single markdown file.

Findings are ranked by **EPSS and CISA KEV, not CVSS**. CVSS scores how bad a bug
would be if exploited and says nothing about whether anyone is exploiting it:
CVE-2025-68121 is rated 10.0 by NVD and sits at the 52nd percentile of exploit
probability. The channel only shows what is in KEV or above the EPSS percentile
for its severity (critical p90, high p95, medium p98, low p99), which is also
what keeps Debian's perpetual "affected, will not fix" entries and CPE collisions
out of it. Everything else is still in the attachment.

A scan that cannot run reports a failure — it never degrades into an all-clear.
If a run dies before reporting, an exit trap posts an ABORTED notice, because
silence and "no findings" must not look the same.

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
