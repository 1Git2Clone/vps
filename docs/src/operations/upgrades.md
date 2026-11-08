# Upgrading a service

How a minor or major version bump of a stateful container goes from "update
available" to merged. Patch bumps that only change the image can skip the cold
snapshot. Anything that migrates a database or changes a config format cannot.

deploy-rs magic rollback reverts the NixOS closure, **not** a volume. A database
migrated by the new version stays migrated after a rollback, and the old version
may refuse to start on it. The cold snapshot is the only undo.

## The procedure

1. **Read what breaks.** Read the upstream changelog for every version between
   the current pin and the target. Write down each breaking change and whether
   it applies here, then check that against the module and the volume, not
   from memory.
2. **Diff the images, not just the notes.** Changelogs miss things. The opendkim
   gid moved in both docker-mailserver majors and neither changelog said so.
   Compare what the module depends on (uids/gids it hardcodes, paths it
   mounts into) between the old and new image:

   ```sh
   # on the desktop, no docker needed; slow (exports the whole image)
   nix run nixpkgs#crane -- export <image> - | tar -x etc/passwd etc/group
   # or on the VPS, which also pre-pulls the image
   sudo docker run --rm --entrypoint id <image> <user>
   ```

3. **Pin by digest**, as `<tag>@sha256:<digest>`. Every tag can move, those
   upstream calls immutable (DMS's `X.Y.Z-rN`) included, and a moved tag means
   the bytes you checked are not the bytes you run. Evaluation fails on a
   registry image without a digest (`modules/containers/default.nix`).
   `nix run nixpkgs#crane -- digest <image>` gives the digest.
4. **Take a cold snapshot**, with the service stopped (see below), and
   **verify it by restoring it**. A snapshot you have not restored is a hope.
5. **Branch, PR, deploy from the branch.** The PR body carries the breaking
   changes, the snapshot id with its restore command, and a Testing section
   filled in after the deploy.
6. **Check the service itself** (per-service lists below). "Deployment
   confirmed" only means the box came back.
7. Merge, once the Testing section is filled in.

## Cold snapshot

Run as root on the VPS. Name every path the service owns: its volumes, plus any
host path it mounts. The trap restarts the service whatever happens.

```sh
P="/var/lib/docker/volumes/<vol1> /var/lib/docker/volumes/<vol2> ..."
trap 'systemctl start docker-<name>' EXIT
systemctl stop docker-<name>          # dependents first, e.g. docker-webmail
restic-b2 backup --tag <name>-cold $P  # prints "snapshot <id> saved"

# Still stopped, so the restore must match the live tree exactly.
restic-b2 restore <id> --target /var/tmp/rt --verify
for p in $P; do diff -r --no-dereference "$p" "/var/tmp/rt$p"; done
rm -rf /var/tmp/rt
```

The `diff` reports `Only in <live>: <x>.sock` and fifos as differences. Restic
does not store sockets and cannot compare fifos. Those are runtime files and
expected. Anything else is a real mismatch. `diff` exits non-zero on them, so
under `set -e` run each path separately, or the loop stops at the first
volume with a socket.

Mail is down while restic runs. For the mail stack (129 MiB) that took
seconds.

## Rolling back

Deploy `main` (the old pin), then restore over the volumes with the service
stopped:

```sh
systemctl stop docker-<name>
restic-b2 restore <id> --target / --delete
systemctl start docker-<name>
```

`--delete` removes files the new version created that the snapshot does not
have. Without it, a half-migrated tree is left behind.

## Forgejo

Done for 16.0.6 → 17.0.1 in #51 (snapshot `0d8781e4`, tag `pre-forgejo-17`).

- **State:** everything is in `forgejo_data`, SQLite included. Postgres is not
  involved.
- **Irreversible:** every minor runs schema migrations on start. Never cross a
  minor without the cold snapshot.
- **Read:** the release notes on codeberg
  (`curl -sS 'https://codeberg.org/api/v1/repos/forgejo/forgejo/releases?limit=5'`),
  looking for renamed `app.ini` settings and removed webhook events. The pages
  hook (`modules/pages-hook.nix`) listens to pushes.
- **Runner:** check the release's minimum `forgejo-runner` version against
  `modules/runner/`. 17's job summaries needed 13.2.
- **Pin:** by digest. 16.0.2's tag still resolved after a manifest behind it
  was deleted, so the tag alone cannot be trusted to stay pullable.
- **Check after deploy:**
  - `curl -s https://git.hu-tao.dev/api/v1/version` shows the new version.
  - A pages site still answers 307 to Anubis.
  - The repo API answers 200:

    ```sh
    curl -s -o /dev/null -w '%{http_code}' \
      https://git.hu-tao.dev/api/v1/repos/hutao/vps
    ```

  - A fresh `git clone` over https works.
  - The PR's own CI run is the runner check.

## Mailserver (docker-mailserver)

Done for 16.0.1 → 17.0.0 in #52 (snapshot `648d9ba6`, tag `mail-cold`), and
15.1.0 → 16.0.1 before it.

- **State:** `dms_mail`, `dms_state`, `dms_config`, `dms_logs`, plus the DKIM
  key at `/var/lib/mailserver/dkim`. Snapshot `roundcube_db` and
  `roundcube_config` in the same run, since webmail is stopped with it anyway.
- **The known trap: opendkim's gid.** `mailserver-dkim` installs the key
  `-o <uid> -g <gid>`, hardcoded. It moved 104 → 102 (v16) and 102 → 103 (v17).
  A wrong gid makes opendkim refuse the key, and submissions get `451 4.7.1`
  **while receiving keeps working**. Diff `/etc/group` every bump.
- **Read:** the CHANGELOG section for the target, especially anything about
  Dovecot config syntax, Rspamd storage, and DKIM key layout. Most breaks miss
  this box because `dms_config` holds only `postfix-accounts.cf`, an empty
  `dovecot-quotas.cf` and `user-patches.sh`, and signing is OpenDKIM via
  KeyTable rather than Rspamd keys. Re-check that list:
  `sudo docker exec mailserver ls -la /tmp/docker-mailserver`.
- **Pin:** `X.Y.Z-rN@sha256:…`. DMS rebuilds releases for Debian updates and
  moves `X.Y.Z` along. Bump the `-rN` too, and re-check the gid. Bump with
  `nix run nixpkgs#crane -- ls ghcr.io/docker-mailserver/docker-mailserver | tail`.
- **Before stopping it**, record per-mailbox counts:
  `docker exec mailserver doveadm mailbox status -A messages '*' > /root/counts-before.txt`.
- **Check after deploy:**
  - `docker exec mailserver id opendkim` shows the new gid. Run the `stat`
    inside the container (`docker exec mailserver sh -c 'stat -c "%u:%g %a" /etc/opendkim/keys/*/default.private'`),
    or the glob expands on the host.
  - `docker exec mailserver supervisorctl status` shows dovecot, postfix,
    opendkim and rspamd RUNNING.
  - `docker exec mailserver opendkim-testkey -d hu-tao.dev -s default -vvv`
    says `key OK`. `key not secure` only means the resolver did not validate
    DNSSEC.
  - The same `doveadm mailbox status` diffs clean against the counts from
    before the upgrade.
  - Send a mail out with a `To:` header and a real body, then check the
    receiving side's headers for `dkim=pass`, `spf=pass` and `dmarc=pass`.
    Gmail may still file a first mail from a new sender as spam. That is a
    reputation verdict, not an authentication failure.

## Roundcube (webmail)

Only patch rebuilds so far (`f833f15`, the php2shell digest pin). No version
bump has been done yet.

- **State:** `roundcube_db` (SQLite) and `roundcube_config`.
- **Irreversible:** the image's entrypoint runs Roundcube's DB schema update on
  start, so a minor bump migrates `roundcube_db`. Snapshot both volumes with
  `docker-webmail` stopped. The mailserver can stay up.
- **Read:** the release notes at github.com/roundcube/roundcubemail for removed
  config options and plugin changes. The plugins in use are listed in
  `ROUNDCUBEMAIL_PLUGINS` in `modules/containers/mailserver.nix`. Check each
  still ships. `managesieve.php` and `remoteip.conf` are mounted in, so check
  those options and Apache module paths still exist.
- **Pin:** by digest, always. The `-apache` tags are rebuilt in place for PHP
  security releases, and a running host does not pick that up on its own.
  Bump with
  `curl -sS 'https://hub.docker.com/v2/repositories/roundcube/roundcubemail/tags?page_size=20&ordering=last_updated'`.
- **Check after deploy:**
  - `sudo docker exec webmail php -v` shows the expected PHP.
  - Webmail loads (tailnet only) and a login works.
  - The access log shows real client addresses, not `172.x`, which is
    `remoteip.conf` still working.
  - Sieve filters open in Settings, which exercises managesieve over TLS.
  - Send a mail from webmail. That exercises submission as the logged-in user.
