# ==============================================================================
# Caddy — TLS terminator
# ==============================================================================
# Caddy does NOT manage certificates. security.acme issues them and caddy reads
# the directory read-only, which is why the global block is empty and every site
# names its files explicitly: a `tls <cert> <key>` directive turns off
# certificate management for that site.
#
# Upstreams are container names, resolved by docker's embedded DNS on the proxy
# network, so a container can be recreated with a new address and caddy is none
# the wiser. The two exceptions are grafana and syncthing: both live in the
# HOST's network namespace, where docker's DNS cannot reach, so they are named
# by the bridge gateway address instead.
#
# The sites split in two. Everything above the "Tailnet-only" marker answers the
# internet on 443; everything below it answers `tailnetHttpsPort`, which the
# firewall exposes to tailscale0 alone.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra)
    domain
    dockerBridgeGateway
    pagesVolume
    runnerIPv4s
    proxyNetwork
    tailnetHttpPort
    tailnetHttpsPort
    ;

  # Same number for the uid and the gid, from modules/ids.nix.
  id = toString config.infra.serviceId.caddy;

  # Stock caddy has no rate limiting, so this is a caddy built with the
  # caddy-ratelimit module compiled in — the ONLY departure from the official
  # image. Version tracks nixpkgs' caddy, which is 2.11.4, the same tag the
  # official image was pinned to, so nothing about caddy's own behaviour moves.
  #
  # withPlugins runs xcaddy and vendors the module's Go deps; `hash` is the
  # fixed-output hash of that vendor tree. Set it to lib.fakeHash, build once,
  # and copy the value the error prints.
  #
  # IT IS NOT ONLY CADDY AND THE PLUGIN THAT MOVE IT. xcaddy writes the Go
  # toolchain version into the generated go.mod — the tree here literally says
  # `go 1.26.7` — so a nixpkgs bump that carries a new Go changes this hash with
  # neither version below touching. 2026-09-17 was exactly that: caddy still
  # 2.11.4, the plugin still v0.1.0, and the hash off by a whole tree.
  #
  # Worse, it does not fail where it changed. A fixed-output derivation is
  # content-addressed, so a store that already has the old tree never re-runs
  # the fetch: the flake update of 2026-09-16 deployed clean from a warm store
  # and the mismatch surfaced the next day on a workstation with a cold one.
  # Expect this after a `nix flake update`, not on the machine that ran it.
  #
  # The module contents are still pinned independently of this value —
  # go.sum carries upstream's hashes for caddy v2.11.4 and the plugin, and a
  # tampered module fails there regardless of what is written here.
  caddyWithRateLimit = pkgs.caddy.withPlugins {
    plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.0" ];
    hash = "sha256-w5ovOoAjzA1HlC2s1GDwKo4fwPJKO3Ou3K/5AiUl4Kk=";
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

  # WHAT A CI RUNNER IS ALLOWED TO ASK git.<domain> FOR. Everything else from a
  # runner address gets a 403.
  #
  # MEASURED, NOT GUESSED. Access logging was turned on for this vhost and a
  # real workflow (hutao/compress Pages, run #7) was driven through it on the
  # new runner. Filtered to the runner's address, the complete set was:
  #
  #    36  POST 200  /api/actions/runner.v1.RunnerService/FetchTask
  #    88  POST 200  /api/actions/runner.v1.RunnerService/UpdateLog
  #    80  POST 200  /api/actions/runner.v1.RunnerService/UpdateTask
  #     1  GET  200  /hutao/compress/info/refs
  #     1  POST 200  /hutao/compress/git-upload-pack
  #
  # Nothing else. In particular no /api/v1 and no web UI, which is what makes
  # this worth doing: the runner's real surface is tiny next to what an
  # address-only control has to leave open.
  #
  # /api/actions_pipeline/* IS THE ONE ENTRY NOT IN THAT LIST, and it is here on
  # purpose. It carries artifact upload, which is how pages publishes now that
  # the job can no longer write the volume (modules/pages-pull.nix). It did not
  # appear in the capture because the upload step failed BEFORE issuing a
  # request — zero requests to that prefix, which is itself how we know the
  # failure was client-side rather than anything at this layer. Leaving it out
  # would guarantee a 403 the moment uploads start working, and the whole point
  # of measuring was to avoid breaking CI in ways that read as a Forgejo fault.
  #
  # The two git paths are wildcarded by owner and repo rather than pinned to the
  # repos that publish today: `actions/checkout` runs in every workflow on every
  # repo this runner serves, and pinning them would turn "someone added a repo"
  # into a checkout failure.
  runnerApiPaths = [
    "/api/actions/*"
    "/api/actions_pipeline/*"
    # v4 ARTIFACT UPLOAD, and it does NOT live under /api/. actions/upload-artifact
    # v4 posts to ACTIONS_RESULTS_URL + this twirp service, and Forgejo sets that
    # variable to the instance ROOT — so the path is top-level and none of the
    # entries above cover it. Probed against the live instance: POST returns 401
    # (route exists, wants the job token) rather than 404, on all of
    # /api/actions_pipeline/_apis/..., this path, and the same path nested under
    # /api/actions_pipeline. Left out, this allowlist would 403 every artifact
    # upload the moment the publishing workflows start working — a self-inflicted
    # break that measurement could not have caught, because no upload has yet
    # got far enough to issue a request.
    "/twirp/github.actions.results.api.v1.ArtifactService/*"
    "/*/*/info/refs"
    "/*/*/git-upload-pack"
  ];

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

      # THE LAYER THAT CAN SEE A PATH. Everything else in this split is an
      # address-and-port control: the cloud firewall, the runner's own nftables,
      # and this host's output chain can all say "that box may reach tcp/443
      # here" and nothing finer. But the runner MUST reach 443 on this host —
      # that is how it fetches jobs — so without something reading the request,
      # a rooted CI job gets the entire Forgejo surface: every repo it can see,
      # the whole web UI, the full /api/v1 with whatever its session carries.
      #
      # remote_ip is the TCP peer and never a header. Caddy consults
      # X-Forwarded-For only when `trusted_proxies` is set, which it is not
      # anywhere in this file, and every record in tofu/modules/cloudflare-dns
      # is `proxied = false`, so nothing sits in front of caddy to launder an
      # address. A root-compromised runner can forge any credential it holds; it
      # cannot forge its source address, because Hetzner assigns it and filters
      # spoofed egress upstream. That is why this is keyed on address rather
      # than on a token.
      #
      # This GRANTS NOTHING. It is a pure restriction applied to a set of
      # addresses, so the worst a mistake here can do is break CI — loudly, in a
      # way a workflow run reports — rather than open something up.
      restrictRunners = true;

    }
    {
      host = "status.${domain}";
      upstream = "kuma:3001";
    }
    {
      host = "pages.${domain}";

      # A document root rather than an upstream: the only site here caddy
      # serves itself. Everything under it is fetched by modules/pages-pull.nix
      # — a timer on this host that pulls each repo's published `pages`
      # artifact out of Forgejo and unpacks it — and caddy reads it read-only.
      #
      # It used to be WRITTEN by the Actions job itself, into the one volume the
      # in-container runner allowed a workflow to mount. A runner on its own box
      # cannot reach this volume and must not, so the direction reversed: the
      # job uploads, this host fetches.
      #
      # The layout IS the URL: /srv/pages/<owner>/<repo>/index.html answers
      # pages.<domain>/<owner>/<repo>/. Nothing maps or rewrites, so a page
      # that 404s is a directory that was never written.
      root = pagesRoot;

      # compress does its work in the browser with a MULTITHREADED ffmpeg
      # build, and a browser hands out SharedArrayBuffer only to a
      # cross-origin-isolated document. Without these two the page loads and
      # then fails on `SharedArrayBuffer is not defined`.
      #
      # Path-scoped, not host-wide, on purpose: require-corp makes every
      # cross-origin subresource opt in with its own CORP header, so a future
      # page here that hotlinks an image or a CDN script would silently stop
      # rendering it. One repo asks for isolation, one repo gets it.
      headers = [
        {
          path = "/hutao/compress/*";
          values = {
            "Cross-Origin-Embedder-Policy" = "require-corp";
            "Cross-Origin-Opener-Policy" = "same-origin";
          };
        }
      ];
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

    # ---- Tailnet-only, below this line -------------------------------------
    #
    # `tailnet = true` is the ONLY difference: it moves the site off 443 and
    # onto `tailnetHttpsPort`, a listener the firewall never exposes to the
    # internet, and the firewall rewrites tailscale0's 443 onto it so the URL
    # still carries no port. Same certificate as everything above — the names
    # are SANs on it, issued over DNS-01, which needs no public A record.
    #
    # Adding one of these to the PUBLIC set is a one-word mistake with no
    # visible symptom: it would simply start answering the internet.
    {
      host = "dozzle.${domain}";
      upstream = "dozzle:8080";
      tailnet = true;
    }
    {
      host = "grafana.${domain}";

      # Not a container name. Grafana runs with --network=host, so it is not on
      # the proxy network and docker's embedded DNS has never heard of it; the
      # route from a container to a host-namespace service is the host's own
      # address on the docker bridge. See `dockerBridgeGateway` in
      # modules/options.nix, and the matching input rule in
      # modules/firewall.nix — without that rule this is a hang, not an error.
      upstream = "${dockerBridgeGateway}:3000";
      tailnet = true;
    }
    {
      host = "syncthing.${domain}";

      # A host service, not even a container. Same route as grafana.
      upstream = "${dockerBridgeGateway}:8384";
      tailnet = true;

      # Syncthing rejects any request whose Host header is neither localhost
      # nor a bare address — an anti-DNS-rebinding check, and the reason its
      # GUI answers 403 "Host check error" behind a proxy that forwards the
      # original Host. Rewriting it to the upstream satisfies the check, which
      # is why that upstream must stay an IP literal rather than a name.
      #
      # The alternative is insecureSkipHostcheck, and that lives in the config
      # directory this repo deliberately does not manage (overrideDevices and
      # overrideFolders are both false — see modules/syncthing.nix), so it
      # would be a hand edit no deploy can reproduce.
      rewriteHost = true;
    }
  ];

  anyRateLimit = lib.any (s: s ? rateLimit) sites;

  tailnetSites = lib.filter (s: s.tailnet or false) sites;

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
        "\tadmin off"
      ]
      # rate_limit is an ordered HTTP handler from a plugin; caddy has no
      # default position for it, so it must be told to run before basic_auth or
      # the 429 would come only after the bcrypt it exists to save. Emitted only
      # when a site actually uses it, so a build without the plugin still
      # validates.
      ++ lib.optionals anyRateLimit [
        "\torder rate_limit before basic_auth"
      ]
      # Caddy enables HTTP/3 on every server it builds, and advertises it with
      # the LISTENER's port — so the tailnet sites would hand the browser
      # `Alt-Svc: h3=":${toString tailnetHttpsPort}"`. Nothing publishes that
      # port over udp and the firewall rewrites tcp only, so every visit would
      # open with a QUIC attempt into a black hole before falling back.
      ++ lib.optionals (tailnetSites != [ ]) [
        "\tservers :${toString tailnetHttpsPort} {"
        "\t\tprotocols h1 h2"
        "\t}"
      ]
      ++ [
        "}"
      ]
      ++ lib.concatMap (
        site:
        [
          ""
          "${site.host}${lib.optionalString (site.tailnet or false) ":${toString tailnetHttpsPort}"} {"
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
        # Response headers, each entry scoped to a path matcher. `header` is an
        # ordered handler with a default position, so unlike rate_limit it
        # needs no `order` line in the global block.
        ++ lib.concatMap (
          h:
          [ "\theader ${h.path} {" ]
          ++ lib.mapAttrsToList (name: value: "\t\t${name} \"${value}\"") h.values
          ++ [ "\t}" ]
        ) (site.headers or [ ])
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
          else if site.rewriteHost or false then
            [
              "\treverse_proxy ${site.upstream} {"
              "\t\theader_up Host {upstream_hostport}"
              "\t}"
            ]
          else if site.restrictRunners or false then
            # `handle` blocks are mutually exclusive and evaluated in order, so
            # the trailing bare `handle` is what every non-runner client falls
            # through to. A plain `reverse_proxy` outside a handle would run for
            # runner requests too and defeat the whole thing.
            [
              "\t@runner remote_ip ${lib.concatStringsSep " " (lib.attrValues runnerIPv4s)}"
              "\thandle @runner {"
              "\t\t@runner_api path ${lib.concatStringsSep " " runnerApiPaths}"
              "\t\thandle @runner_api {"
              "\t\t\treverse_proxy ${site.upstream}"
              "\t\t}"
              "\t\trespond \"not permitted from a CI runner\" 403"
              "\t}"
              "\thandle {"
              "\t\treverse_proxy ${site.upstream}"
              "\t}"
            ]
          else
            [ "\treverse_proxy ${site.upstream}" ]
        )
        ++ [ "}" ]
      ) sites
      # One block for all of them: a site address with an explicit port gets no
      # automatic http->https redirect from caddy, and a 404 from the public :80
      # listener is a worse answer than a redirect. See `tailnetHttpPort`.
      ++ lib.optionals (tailnetSites != [ ]) [
        ""
        "${lib.concatMapStringsSep ", " (s: "http://${s.host}:${toString tailnetHttpPort}") tailnetSites} {"
        "\tredir https://{host}{uri}"
        "}"
      ]
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

      # The tailnet listeners. Published on 0.0.0.0 like everything else and
      # kept private the same way dozzle:8080 always has been — neither port is
      # in the firewall's public allow-lists, so only `iifname tailscale0
      # accept` reaches them.
      "${toString tailnetHttpPort}:${toString tailnetHttpPort}"
      "${toString tailnetHttpsPort}:${toString tailnetHttpsPort}"
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
