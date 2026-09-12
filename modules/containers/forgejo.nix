# ==============================================================================
# Forgejo — git hosting
# ==============================================================================
# Publishes the host's port 22, so clone URLs need no port: ssh reads no SRV
# record, so anything other than 22 has to be spelled out in every remote or
# every client's ~/.ssh/config. The host's own sshd is therefore on 2222 (see
# modules/services.nix) and administrative access is over Tailscale SSH.
#
# The consequence is that forgejo's in-container OpenSSH absorbs the internet's
# routine SSH scanning, which is what the fail2ban forgejo-ssh jail watches.
{ config, ... }:

let
  inherit (config.infra) domain proxyNetwork;
  fqdn = "git.${domain}";
in
{
  virtualisation.oci-containers.containers.forgejo = {
    # 16.0.4, a PATCH release within 16.0, and the reason to take it promptly is
    # that it is a security release. Its notes carry a Critical fix: template
    # expansion during "generate repository from template" could plant a `.git`
    # folder that git then adopted, giving arbitrary file read and remote code
    # execution ON THIS HOST. Alongside it, an API access-token scope bypass via
    # the "allow maintainer edit" path, and draft-release attachments readable
    # by anyone including anonymous callers on public repos — the same class
    # Gitea fixed as CVE-2026-27660.
    #
    # This repo is public and this instance runs Actions, so "wait and see" was
    # the more expensive option, not the safer one.
    #
    # The standing caution still applies to MINOR and MAJOR bumps: a forgejo
    # upgrade runs irreversible database migrations, and deploy-rs magic
    # rollback reverts the closure, NOT the database. It cannot save a migrated
    # schema. The backup can — restic to B2 covers /var/lib/docker/volumes daily
    # (modules/backups.nix), so forgejo_data has a restore point. Run
    # `systemctl start restic-backups-b2.service` before a bump that crosses a
    # minor, so the restore point is minutes old rather than up to a day.
    #
    # History worth keeping: 16.0.2 is UNPULLABLE. Its tag still resolves on
    # codeberg but a platform manifest inside the index (sha256:398cb21d…) was
    # deleted, so a rebuild from scratch cannot reach it. That is what forced
    # the move to 16.0.3 during the data migration.
    #
    # Bump with: curl -sS 'https://codeberg.org/api/v1/repos/forgejo/forgejo/releases?limit=5'
    image = "codeberg.org/forgejo/forgejo:16.0.4";

    # journald, so the fail2ban jail can read the SSH auth failures at all. The
    # default json-file driver writes to a path containing the container ID and
    # nothing reaches the journal.
    log-driver = "journald";
    # Without a tag the journal identifier is the container ID, which changes on
    # every recreate — and the jail's journalmatch would go stale silently.
    extraOptions = [
      "--log-opt"
      "tag=forgejo"
    ];

    environment = {
      USER_UID = "1000";
      USER_GID = "1000";

      FORGEJO__service__DISABLE_REGISTRATION = "true";
      FORGEJO__service__REQUIRE_SIGNIN_VIEW = "false";
      FORGEJO__admin__DISABLE_REGULAR_ORG_CREATION = "true";
      FORGEJO__actions__ENABLED = "true";

      FORGEJO__server__DOMAIN = fqdn;
      FORGEJO__server__SSH_DOMAIN = fqdn;
      FORGEJO__server__HTTP_PORT = "4242";
      FORGEJO__server__SSH_PORT = "22";
      FORGEJO__server__ROOT_URL = "https://${fqdn}/";
    };

    ports = [ "22:22" ];

    volumes = [
      "forgejo_data:/data"
      "/etc/localtime:/etc/localtime:ro"
    ];

    networks = [ proxyNetwork ];
  };
}
