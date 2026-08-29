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
    # 16.0.3, and the version choice is deliberate rather than "newest wins".
    #
    # A forgejo upgrade runs irreversible database migrations, so normally the
    # right move during a data migration is to change nothing. 16.0.2 forces the
    # issue: its tag still resolves on codeberg, but a platform manifest inside
    # the index (sha256:398cb21d…) has been deleted, so the image is UNPULLABLE.
    # The old box only runs it because it pulled while the blob still existed. A
    # config that cannot rebuild from scratch is the thing this repo exists to
    # avoid, so staying on 16.0.2 was not an option.
    #
    # The migration risk is covered rather than accepted: the old box keeps
    # pristine 16.0.2 data and is untouched, and the new box works from an rsync
    # COPY. If 16.0.3's migrations go wrong the rollback is to stop using the new
    # box — nothing is lost.
    #
    # Bump with: curl -sS 'https://codeberg.org/api/v1/repos/forgejo/forgejo/releases?limit=5'
    image = "codeberg.org/forgejo/forgejo:16.0.3";

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
