# ==============================================================================
# Forgejo — git hosting
# ==============================================================================
# Publishes the host's port 22, so clone URLs need no port: ssh reads no SRV
# record, so anything other than 22 has to be spelled out in every remote or
# every client's ~/.ssh/config. The host's own sshd is therefore on 2222 (see
# modules/services.nix), and that is the administrative way in.
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
    # 16.0.5, a PATCH release within 16.0, and the reason to take it promptly is
    # that it is a security release. Its notes carry a Critical fix: a patch
    # applied through the web UI, web cherry-pick or the `/diffpatch` API could
    # make `git apply` rewrite the temporary bare repo's own config, giving
    # remote code execution ON THIS HOST — a variant of the 15.0.6 fix that was
    # missed at the time. Alongside it, a CSRF that could attach an attacker's
    # OpenID identity to a logged-in account, and OpenID sign-in is on here.
    #
    # 16.0.4 before it fixed the same class through template expansion
    # planting a `.git` folder, plus an access-token scope bypass and
    # draft-release attachments readable anonymously on public repos.
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
    image = "codeberg.org/forgejo/forgejo:16.0.5@sha256:cf5f5ae6acf2ababca0ee3d255705b83a47f35b25e07fc931d694d60664053fe";

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

      # THE INSTALL WIZARD, CLOSED EXPLICITLY RATHER THAN BY THE VOLUME BEING
      # NON-EMPTY. The image's setup script writes app.ini only when it is
      # absent, and it flips INSTALL_LOCK itself only when SECRET_KEY is set —
      # which it is not here. So an instance whose forgejo_data volume has no
      # app.ini serves /install to whoever asks, and completing that wizard sets
      # the admin account and the database settings.
      #
      # Nothing is exploitable on the running instance, whose volume was
      # populated long ago. The window is a restore or a rebuild onto fresh
      # storage, where git.<domain> is public on 443 with no basic_auth
      # (modules/containers/caddy.nix) and the operator is racing the internet
      # to finish setup. This turns that race into a 500 and no admin account,
      # which is a deploy that visibly failed rather than one that quietly let
      # someone else finish it.
      FORGEJO__security__INSTALL_LOCK = "true";

      FORGEJO__service__DISABLE_REGISTRATION = "true";
      FORGEJO__service__REQUIRE_SIGNIN_VIEW = "false";
      FORGEJO__admin__DISABLE_REGULAR_ORG_CREATION = "true";
      FORGEJO__actions__ENABLED = "true";

      # WITHOUT THIS, THE PAGES WEBHOOK SILENTLY NEVER FIRES.
      #
      # ALLOWED_HOST_LIST defaults to `external` (Gitea 1.16 and later), which
      # permits public addresses and BLOCKS private ones. The pages receiver is
      # a container on this same network, so every delivery is refused by
      # Forgejo's own policy before a socket is opened.
      #
      # That last part is what makes it nasty to diagnose: everything on the
      # RECEIVING side looks perfect. The socket is listening, the rule matches,
      # and there is no dropped packet, no connection refused and nothing in the
      # receiver's journal, because nothing is ever sent.
      #
      # LOOK AT THE SENDER. Forgejo logs the refusal as an error on its own
      # service, which is the fastest way to identify this:
      #
      #   journalctl -u docker-forgejo | grep -i 'unable to deliver webhook'
      #
      # An earlier version of this comment claimed the hook's settings page was
      # the only trace. That was wrong, and wrong in the direction that costs an
      # hour: it sends you looking at a web form instead of at the log line that
      # names the URL and the reason.
      #
      # THE CONTAINER NAME, not an address. This was `infra.dockerBridgeGateway`
      # while the receiver ran on the host, and that was too wide: the list
      # matches HOSTS, NOT host:port, so allowing 172.17.0.1 allowed a webhook
      # aimed at anything bound there — grafana (3000), syncthing's GUI (8384),
      # tempo (4317/4318) and pgbouncer (6432) all bind 0.0.0.0 and answer on
      # it. Forgejo webhooks can use GET and record the RESPONSE BODY in their
      # delivery history, so it was a read primitive with an exfiltration
      # channel: whoever could create a webhook could read tailnet-only services
      # without being on the tailnet.
      #
      # A name works because the matcher is
      # `MatchHostName(host) || MatchIPAddr(ip)` (modules/hostmatcher) — a name
      # pattern alone is sufficient, and the resolved private IP never has to be
      # allowed. So this permits exactly one destination and 172.17.0.1 stops
      # matching at all.
      FORGEJO__webhook__ALLOWED_HOST_LIST = "pages-hook";

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
