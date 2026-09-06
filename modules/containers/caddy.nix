# ==============================================================================
# Caddy — TLS terminator
# ==============================================================================
# Caddy does NOT manage certificates. security.acme issues them and caddy reads
# the directory read-only, which is why the global block is empty and every site
# names its files explicitly: a `tls <cert> <key>` directive turns off
# certificate management for that site.
#
# Upstreams are container names, resolved by docker's embedded DNS on the proxy
# network. Nothing here is an IP address, so a container can be recreated with a
# new address and caddy is none the wiser.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain pagesVolume proxyNetwork;

  # Same number for the uid and the gid, from modules/ids.nix.
  id = toString config.infra.serviceId.caddy;

  # Stock caddy has no rate limiting, so this is a caddy built with the
  # caddy-ratelimit module compiled in — the ONLY departure from the official
  # image. Version tracks nixpkgs' caddy, which is 2.11.4, the same tag the
  # official image was pinned to, so nothing about caddy's own behaviour moves.
  #
  # withPlugins runs xcaddy and vendors the module's Go deps; `hash` is the
  # fixed-output hash of that vendor tree. Bump the plugin or caddy and the
  # hash changes — set it to lib.fakeHash, build once, and copy the value the
  # error prints.
  caddyWithRateLimit = pkgs.caddy.withPlugins {
    plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.0" ];
    hash = "sha256-u/cMyier+OMIyNnr8QbodVn+lgK35H82lGn6N8k+g+A=";
  };

  # A minimal image around that binary, matching the two things the official
  # image does that caddy depends on: XDG_*_HOME point at the writable tmpfs
  # mounts (a read-only rootfs otherwise sends caddy to $HOME/.local and it
  # exits), and the same entrypoint/args. cacert is for outbound TLS trust —
  # unused today (acme is external, upstreams are plaintext) but cheap
  # insurance against a future directive that dials out.
  caddyImage = pkgs.dockerTools.buildLayeredImage {
    name = "caddy-ratelimit";
    tag = pkgs.caddy.version;
    contents = [ pkgs.cacert ];
    config = {
      Entrypoint = [ "${caddyWithRateLimit}/bin/caddy" ];
      Cmd = [
        "run"
        "--config"
        "/etc/caddy/Caddyfile"
        "--adapter"
        "caddyfile"
      ];
      Env = [
        "XDG_CONFIG_HOME=/config"
        "XDG_DATA_HOME=/data"
      ];
    };
  };

  # The certificate directory as caddy sees it. NixOS names the private key
  # key.pem, NOT privkey.pem as certbot did — pointing at the wrong name here
  # fails the whole config load, so it is at least loud.
  certDir = "/etc/caddy/certs";

  # Where the pages volume is mounted inside this container.
  pagesRoot = "/srv/pages";

  sites = [
    {
      host = "music.${domain}";
      upstream = "navidrome:4533";
    }
    {
      host = "mail.${domain}";
      upstream = "webmail:80";
    }
    {
      host = "git.${domain}";
      upstream = "forgejo:4242";
    }
    {
      host = "status.${domain}";
      upstream = "kuma:3001";
    }
    {
      host = "pages.${domain}";

      # A document root rather than an upstream: the only site here caddy
      # serves itself. Everything under it is written by an Actions workflow
      # (see modules/containers/forgejo-runner.nix) into the ONE volume a
      # workflow is allowed to mount, and caddy reads it read-only.
      #
      # The layout IS the URL: /srv/pages/<owner>/<repo>/index.html answers
      # pages.<domain>/<owner>/<repo>/. Nothing maps or rewrites, so a page
      # that 404s is a directory that was never written.
      root = pagesRoot;
    }
    {
      host = "search.${domain}";
      upstream = "searxng:8080";

      # searxng has no accounts of its own, so this is the ONLY thing standing
      # between the instance and the open internet — see
      # modules/containers/searxng.nix.
      #
      # `{$VAR}` is caddy's own environment substitution, done when it loads
      # this file. The values are deliberately not Nix strings: this Caddyfile
      # becomes a world-readable store path, and a bcrypt hash in the store is
      # a bcrypt hash anyone with shell on the box can start cracking.
      basicAuth = {
        user = "{$SEARXNG_USER}";
        hash = "{$SEARXNG_PASSWORD_HASH}";
      };

      # Caps repeated hits per client IP, returning 429 BEFORE basic_auth runs
      # its bcrypt (see the global `order` below) — so a password flood cannot
      # turn cost-14 verifications into CPU exhaustion. In-process: a misconfig
      # throttles requests, it cannot take the box down the way the
      # forward-chain fail2ban jail did.
      #
      # events/window is a KNOB, not a law. It counts EVERY request to the
      # site, and image_proxy means one results page pulls many thumbnails
      # through caddy, so this has to sit well above a human's page-load burst
      # while still being far under a flood. Caddy caches a successful
      # verification, so a logged-in user rarely re-pays bcrypt anyway; the
      # thing being limited is mostly the attacker who never authenticates.
      # Tune against real 429s in the access log if browsing ever trips it.
      rateLimit = {
        events = 120;
        window = "1m";
      };
    }
  ];

  anyRateLimit = lib.any (s: s ? rateLimit) sites;

  # Tabs and this exact shape are what `caddy fmt` produces, so `caddy validate`
  # on the generated file is clean rather than warning about formatting every
  # time someone checks it.
  caddyfile = pkgs.writeText "Caddyfile" (
    lib.concatStringsSep "\n" (
      [
        "# Generated by Nix — edit modules/containers/caddy.nix"
        "{"
        "\t# Certificates come from security.acme on the host."
        "\t# See the `tls` directive on each site below."
        "\t admin off"
      ]
      # rate_limit is an ordered HTTP handler from a plugin; caddy has no
      # default position for it, so it must be told to run before basic_auth or
      # the 429 would come only after the bcrypt it exists to save. Emitted only
      # when a site actually uses it, so a build without the plugin still
      # validates.
      ++ lib.optionals anyRateLimit [
        "\torder rate_limit before basic_auth"
      ]
      ++ [
        "}"
      ]
      ++ lib.concatMap (
        site:
        [
          ""
          "${site.host} {"
          "\ttls ${certDir}/fullchain.pem ${certDir}/key.pem"
        ]
        # Zone keyed on {remote_host} — the client IP — so one address's flood
        # cannot exhaust the budget for everyone. The zone name is the host, so
        # two rate-limited sites keep separate counters.
        ++ lib.optionals (site ? rateLimit) [
          "\trate_limit {"
          "\t\tzone ${site.host} {"
          "\t\t\tkey {remote_host}"
          "\t\t\tevents ${toString site.rateLimit.events}"
          "\t\t\twindow ${site.rateLimit.window}"
          "\t\t}"
          "\t}"
        ]
        # `basic_auth`, not `basicauth`: renamed in caddy 2.8, and the old
        # spelling is a hard config-load error rather than a warning.
        ++ lib.optionals (site ? basicAuth) [
          "\tbasic_auth {"
          "\t\t${site.basicAuth.user} ${site.basicAuth.hash}"
          "\t}"
        ]
        ++ (
          if site ? root then
            [
              "\troot * ${site.root}"
              # No `browse`: a missing index.html is a 404, not a listing of
              # whatever else the workflow put there.
              "\tfile_server"
            ]
          else
            [ "\treverse_proxy ${site.upstream}" ]
        )
        ++ [ "}" ]
      ) sites
    )
    + "\n"
  );
in
{
  # The credential for the basic_auth site above. An environment file rather
  # than a mounted one on purpose: docker reads --env-file at container START
  # and copies the values in, so it resolves the sops generation symlink each
  # time. A *mounted* template would be resolved once and then pinned to a
  # stale inode — the problem dozzle-users.service exists to work around.
  sops.templates."caddy.env".content = ''
    SEARXNG_USER=${config.sops.placeholder.searxng_admin_user}
    SEARXNG_PASSWORD_HASH=${config.sops.placeholder.searxng_admin_password_hash}
  '';

  virtualisation.oci-containers.containers.caddy = {
    # Built locally rather than pulled — caddy 2.11.4 plus the rate-limit
    # module. imageFile loads the tarball; image just names what it loaded.
    image = "caddy-ratelimit:${pkgs.caddy.version}";
    imageFile = caddyImage;

    environmentFiles = [ config.sops.templates."caddy.env".path ];

    ports = [
      "80:80"
      "443:443"
      # HTTP/3. The nftables input chain has to allow udp 443 for this to be
      # more than decoration.
      "443:443/udp"
    ];

    volumes = [
      "${caddyfile}:/etc/caddy/Caddyfile:ro"
      "/var/lib/acme/${domain}:${certDir}:ro"
      # Read-only, and written only by workflow jobs. Docker creates the volume
      # empty on first start, so every pages URL 404s until something publishes.
      "${pagesVolume}:${pagesRoot}:ro"
    ];

    networks = [ proxyNetwork ];

    extraOptions = [
      # Not root. The certificate directory is group-owned by `caddy` (see
      # modules/acme.nix), so this account reads exactly those files and
      # nothing else on the host.
      "--user=${id}:${id}"

      "--read-only"
      "--security-opt=no-new-privileges:true"

      # NET_BIND_SERVICE is NOT for binding: docker sets
      # net.ipv4.ip_unprivileged_port_start=0, so any uid may bind 80 and 443.
      # It is here because /usr/bin/caddy carries a file capability, and the
      # kernel refuses to exec such a binary when the bounding set is empty —
      # `--cap-drop=ALL` alone fails with "exec: operation not permitted"
      # before caddy runs at all.
      "--cap-drop=ALL"
      "--cap-add=NET_BIND_SERVICE"

      # /data and /config were named volumes, which a non-root container cannot
      # write because docker creates them root-owned. They are ephemeral here
      # instead: with certificates supplied by acme and the admin API off, that
      # storage holds OCSP staples and an autosave, both re-derived on start.
      # uid/gid rather than mode=1777, so nothing in the container is
      # world-writable.
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m,uid=${id},gid=${id},mode=0700"
      "--tmpfs=/data:rw,nosuid,nodev,size=16m,uid=${id},gid=${id},mode=0700"
      "--tmpfs=/config:rw,nosuid,nodev,size=4m,uid=${id},gid=${id},mode=0700"
    ];
  };

  # acme writes the certificate before anything can serve it. Without this a
  # first boot starts caddy against an empty directory and it exits.
  systemd.services.docker-caddy = {
    after = [ "acme-${domain}.service" ];
    wants = [ "acme-${domain}.service" ];
  };
}
