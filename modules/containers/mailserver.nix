# ==============================================================================
# Mailserver — docker-mailserver + roundcube
# ==============================================================================
# SMTP/IMAP are published directly on 25/465/587/993: an MX record has to be
# reachable at the host, so none of this can sit behind cloudflared. Only the
# webmail is proxied, at mail.<domain>.
{ config, pkgs, ... }:

let
  inherit (config.infra) domain proxyNetwork;
  hostname = "smtp.${domain}";

  # DMS resolves its certificate as $SSL_DOMAIN then $HOSTNAME then $DOMAINNAME
  # under SSL_TYPE=letsencrypt, which is what forced the certbot lineage to be
  # called smtp.<domain>. security.acme's layout is not certbot's, so point DMS
  # at the files directly instead and the guessing stops.
  certDir = "/certs";

  # The signing key's public half is published in DNS from tofu/. Losing or
  # replacing this file means republishing DNS, so it is deployed to a stable
  # path and mounted read-only.
  dkimKey = "/var/lib/mailserver/dkim/default.private";
  dkimKeyInContainer = "/etc/opendkim/keys/${domain}/default.private";

  # RFC 5321 §4.5.1 requires postmaster@ to be deliverable, and until now it was
  # not: the domain is a virtual mailbox domain with no alias map at all, so
  # postfix accepted the recipient, handed it to dovecot, and dovecot answered
  # `550 5.1.1 User doesn't exist`. That also silently swallowed this box's own
  # system mail, because POSTMASTER_ADDRESS points /etc/aliases' `root:` at the
  # very address that was bouncing. Found on 2026-09-16 while checking whether
  # an outage had lost any mail; the oldest bounce in the log was 2026-09-13.
  #
  # abuse@ is not required the way postmaster@ is, but RFC 2142 asks for it and
  # it is the address an operator reaches for before reaching for a blocklist.
  #
  # A plain string, not a sops secret, on the same reasoning infra.acmeEmail is
  # written down: a contact address is not a credential. The target is the one
  # real mailbox on the domain.
  aliasTarget = "ivan@${domain}";

  # DMS reads this out of its config volume and compiles it into
  # /etc/postfix/virtual. Declared here rather than created with
  # `setup alias add`, which writes into the dms_config VOLUME — an alias that
  # lives only there is state this repo does not describe, and it does not
  # survive the volume being lost.
  #
  # Mounted nested inside that volume, the same way dozzle's users.yml and
  # roundcube's managesieve.php are: docker orders bind mounts by destination
  # depth, so the volume is mounted first and this file lands on top of it.
  #
  # The trade, stated plainly: the mount is read-only, so `setup alias add` will
  # fail from now on. Aliases are a git change. That is the intent, not a
  # side effect.
  virtualAliases = pkgs.writeText "postfix-virtual.cf" ''
    postmaster@${domain} ${aliasTarget}
    abuse@${domain} ${aliasTarget}
  '';

  # Roundcube's managesieve plugin defaults to a plaintext localhost connection,
  # which is wrong on a container network: the host is the mailserver container
  # and the TLS peer name must match the certificate, not the container name.
  managesieve = pkgs.writeText "managesieve.php" ''
    <?php
    $config['managesieve_host'] = 'tls://mailserver:4190';
    $config['managesieve_conn_options'] = [
        'ssl' => [
            'verify_peer' => true,
            'verify_peer_name' => true,
            'peer_name' => '${hostname}',
        ],
    ];
  '';
in
{
  sops.templates."dms.env".content = ''
    POSTMASTER_ADDRESS=${config.sops.placeholder.email_postmaster}
  '';

  # ONLY the des_key. It is the single secret roundcube needs, and a sops
  # template must contain nothing else — anything non-secret in here reads as a
  # credential to whoever opens the file next.
  sops.templates."roundcube.env".content = ''
    ROUNDCUBEMAIL_DES_KEY=${config.sops.placeholder.email_roundcube_des_key}
  '';

  # Same reasoning as dozzle's users file: a rendered secret's real path lives
  # under a generation directory, and docker would pin the old inode. Copying to
  # a stable path is what makes the mount survive a secret rotation.
  systemd.services.mailserver-dkim = {
    description = "Install the DKIM signing key";
    requiredBy = [ "docker-mailserver.service" ];
    before = [ "docker-mailserver.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # 0600, owned by DMS's opendkim uid — NOT 0644.
    #
    # opendkim enforces RequireSafeKeys (on by default, and not overridden in
    # DMS's opendkim.conf): it REFUSES to load a signing key that is
    # world-readable. A 0644 key produces
    #
    #   opendkim: <id>: error loading key 'default._domainkey.<domain>'
    #
    # and then, because opendkim is a milter on the outbound path, postfix
    # answers submissions with "451 4.7.1 Service unavailable - try again
    # later". Receiving keeps working, so the failure looks like anything
    # except a file mode. The key itself is valid and matches DNS throughout.
    #
    # 102:102 are opendkim's uid:gid inside the DMS image, which has no
    # counterpart on this host — hence numeric. Verify after an image bump with:
    #   docker exec mailserver id opendkim
    #
    # THAT VERIFY STEP IS NOT DECORATIVE. It caught a real break on the
    # 15.1.0 -> 16.0.1 bump: the gid moved 104 -> 102 while the uid stayed put,
    # because v16 rebases onto Debian 13 and the package install order that
    # allocates it changed. Installing the key -g 104 under v16 hands it to a
    # group opendkim is not in, RequireSafeKeys refuses to load it, and
    # submissions get 451 4.7.1 while RECEIVING still works — the exact silent
    # half-failure described above. Check the IMAGE before deploying it, which
    # needs no running container and no downtime:
    #   docker run --rm --entrypoint id <image> opendkim
    #
    # The mount is read-only, so DMS cannot correct the mode itself the way it
    # does for keys it manages in its own config volume.
    script = ''
      install -d -m 0700 -o root -g root /var/lib/mailserver/dkim
      install -m 0600 -o 102 -g 102 \
        ${config.sops.secrets.email_dkim_private_key.path} ${dkimKey}
    '';
  };

  virtualisation.oci-containers.containers = {
    mailserver = {
      # v16.0.1, a MAJOR: Debian 12 -> 13, and with it Postfix 3.7.11 ->
      # 3.10.13 and Dovecot 2.3.19.1 -> 2.4.1-4.
      #
      # What makes it safe for THIS deployment is mostly what dms_config does
      # not contain. There is no custom dovecot.cf — 2.3 syntax does not load
      # under 2.4 — and no dhparams.pem, which v16 stopped applying when it
      # dropped DHE from 465/587/993. The volume holds exactly three things:
      # postfix-accounts.cf, an empty dovecot-quotas.cf, and user-patches.sh.
      #
      # user-patches.sh writes the OpenDKIM KeyTable/SigningTable/TrustedHosts,
      # which is also why v16's Rspamd DKIM key rename to
      # <domain>-<selector>.private does not apply: signing here is OpenDKIM
      # and the key path is pinned by that KeyTable, not discovered.
      #
      # SA_SPAM_SUBJECT was removed in favour of SPAM_SUBJECT; neither is set
      # below, so there is nothing to migrate. The gid change this bump carries
      # is handled in mailserver-dkim above — read that comment before touching
      # the tag again.
      #
      # Bump with: curl -sS 'https://api.github.com/repos/docker-mailserver/docker-mailserver/releases?per_page=5'
      image = "ghcr.io/docker-mailserver/docker-mailserver:16.0.1";
      inherit hostname;

      environment = {
        SSL_TYPE = "manual";
        SSL_CERT_PATH = "${certDir}/fullchain.pem";
        SSL_KEY_PATH = "${certDir}/key.pem";

        ENABLE_IMAP = "1";
        ENABLE_POP3 = "0";

        ENABLE_RSPAMD = "1";
        ENABLE_CLAMAV = "0";
        ENABLE_FAIL2BAN = "1";

        # Dovecot ManageSieve on 4190, for roundcube's managesieve plugin.
        ENABLE_MANAGESIEVE = "1";

        # Nothing on the docker networks is a trusted mail client.
        PERMIT_DOCKER = "none";
      };

      environmentFiles = [ config.sops.templates."dms.env".path ];

      ports = [
        "25:25"
        "465:465"
        "587:587"
        "993:993"
      ];

      volumes = [
        "dms_mail:/var/mail"
        "dms_state:/var/mail-state"
        "dms_logs:/var/log/mail"
        "dms_config:/tmp/docker-mailserver"
        # Nested inside the volume above; see the comment on virtualAliases.
        "${virtualAliases}:/tmp/docker-mailserver/postfix-virtual.cf:ro"
        "/var/lib/acme/${domain}:${certDir}:ro"
        "/etc/localtime:/etc/localtime:ro"
        "${dkimKey}:${dkimKeyInContainer}:ro"
      ];

      # DMS runs its own fail2ban, which needs to write iptables rules inside
      # its own network namespace.
      capabilities.NET_ADMIN = true;

      networks = [ proxyNetwork ];
    };

    webmail = {
      image = "roundcube/roundcubemail:1.7.4-apache";

      environment = {
        ROUNDCUBEMAIL_DEFAULT_HOST = "ssl://${hostname}";
        ROUNDCUBEMAIL_DEFAULT_PORT = "993";

        ROUNDCUBEMAIL_SMTP_SERVER = "tls://${hostname}";
        ROUNDCUBEMAIL_SMTP_PORT = "587";

        # NOT credentials. "%u" and "%p" are literally those two characters —
        # roundcube's own placeholders, which it replaces at request time with
        # the username and password of whoever is logged in, held only in that
        # user's session. Each person therefore authenticates to submission as
        # themselves. Writing a real account here would make every user send as
        # that one account.
        #
        # These match roundcube's built-in defaults; they are spelled out
        # because submission auth silently failing is what "554 5.7.1 Client
        # host rejected" looks like, and a default you cannot see is a bad thing
        # to depend on for that.
        ROUNDCUBEMAIL_SMTP_USER = "%u";
        ROUNDCUBEMAIL_SMTP_PASSWORD = "%p";

        ROUNDCUBEMAIL_DB_TYPE = "sqlite";
        ROUNDCUBEMAIL_SKIN = "elastic";
        ROUNDCUBEMAIL_PLUGINS = "archive,zipdownload,managesieve,markasjunk,show_additional_headers,hide_blockquote,newmail_notifier";
      };

      environmentFiles = [ config.sops.templates."roundcube.env".path ];

      volumes = [
        "roundcube_db:/var/roundcube/db"
        "roundcube_config:/var/roundcube/config"
        # Nested inside the volume above; docker mounts by destination depth.
        "${managesieve}:/var/roundcube/config/managesieve.php:ro"
      ];

      dependsOn = [ "mailserver" ];
      networks = [ proxyNetwork ];
    };
  };

  systemd.services.docker-mailserver = {
    after = [ "acme-${domain}.service" ];
    wants = [ "acme-${domain}.service" ];
  };
}
