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
    # 102:104 are opendkim's uid:gid inside the DMS image, which has no
    # counterpart on this host — hence numeric. Verify after an image bump with:
    #   docker exec mailserver id opendkim
    #
    # The mount is read-only, so DMS cannot correct the mode itself the way it
    # does for keys it manages in its own config volume.
    script = ''
      install -d -m 0700 -o root -g root /var/lib/mailserver/dkim
      install -m 0600 -o 102 -g 104 \
        ${config.sops.secrets.email_dkim_private_key.path} ${dkimKey}
    '';
  };

  virtualisation.oci-containers.containers = {
    mailserver = {
      image = "ghcr.io/docker-mailserver/docker-mailserver:15.1.0";
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
      image = "roundcube/roundcubemail:1.7.3-apache";

      environment = {
        ROUNDCUBEMAIL_DEFAULT_HOST = "ssl://${hostname}";
        ROUNDCUBEMAIL_DEFAULT_PORT = "993";

        ROUNDCUBEMAIL_SMTP_SERVER = "tls://${hostname}";
        ROUNDCUBEMAIL_SMTP_PORT = "587";

        ROUNDCUBEMAIL_DB_TYPE = "sqlite";
        ROUNDCUBEMAIL_SKIN = "elastic";
        ROUNDCUBEMAIL_PLUGINS = "archive,zipdownload,managesieve,markasjunk,show_additional_headers,hide_blockquote,newmail_notifier";
      };

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
