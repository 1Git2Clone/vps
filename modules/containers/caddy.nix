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

  # HSTS, emitted on EVERY site block below — caddy adds nothing of the sort on
  # its own, and until this line every vhost here answered without it
  # (`curl -D - https://git.<domain>/` showed no Strict-Transport-Security on
  # any of the six public names).
  #
  # What it buys is the first request. Every name here is already https-only and
  # caddy already redirects http->https, but that redirect is a plaintext round
  # trip that a network attacker can answer instead — sslstrip against
  # mail.<domain>'s login form, say. After one https visit the browser stops
  # making it.
  #
  # NO `preload`. That is a submission to a list baked into browser binaries,
  # removal takes months, and it would cover the APEX and therefore every
  # subdomain — including ones this caddy does not serve. includeSubDomains here
  # is scoped to the name that sent it (so `git.<domain>` covers
  # `*.git.<domain>`, not its siblings), which costs nothing and is not a
  # commitment anyone else has to honour.
  #
  # On the tailnet sites too: same certificate, same https, and a browser that
  # has pinned dozzle.<domain> is a browser that cannot be walked onto the
  # plaintext listener. The http->https redirect block at the bottom of this
  # file deliberately does NOT carry it — a browser ignores HSTS on a plaintext
  # response, so it would be decoration.
  hsts = ''Strict-Transport-Security "max-age=31536000; includeSubDomains"'';

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
  # ARTIFACT UPLOAD is the one thing that capture could not show, because at the
  # time it was taken no upload had ever issued a request: actions/upload-artifact
  # v4 bundles @actions/artifact v2, which tests GITHUB_SERVER_URL's hostname
  # against GITHUB.COM and *.GHE.COM, decides a Forgejo instance is a self-hosted
  # GitHub Enterprise Server, and throws before opening a socket. Zero requests
  # from the runner is exactly what that looks like from here, and it is why no
  # amount of work at this layer could have fixed it. The publishing workflows now
  # use code.forgejo.org/forgejo/upload-artifact, whose one patch is to drop that
  # check, and the upload route it actually uses is the twirp service below.
  #
  # The two git paths are wildcarded by owner and repo rather than pinned to the
  # repos that publish today: `actions/checkout` runs in every workflow on every
  # repo this runner serves, and pinning them would turn "someone added a repo"
  # into a checkout failure.
  runnerApiPaths = [
    "/api/actions/*"
    # ARTIFACT TRANSFER, AND IT DOES NOT LIVE UNDER /api/. upload-artifact posts to
    # ACTIONS_RESULTS_URL + this twirp service, and Forgejo sets that variable to
    # the instance ROOT, so the path is top-level and the entry above does not
    # cover it. Added on the strength of a probe (POST returns 401 — route exists,
    # wants the job token — rather than 404) and since CONFIRMED by real traffic:
    # hutao/compress artifact 15 and skavex/skavex artifact 14 both uploaded
    # through it, and modules/pages-pull.nix fetched and unpacked both.
    #
    # One wildcard covers download as well as upload — ListArtifacts and
    # GetSignedArtifactURL are methods on the same service — which matters if a
    # workflow ever consumes an artifact rather than only producing one.
    #
    # /api/actions_pipeline/* WAS HERE AND IS DELIBERATELY GONE. It is the v3
    # artifact API, added defensively when the guess was that uploads rode it.
    # They do not: a full run's capture never touched it, and the upload that now
    # works goes to the twirp service instead. An allow-list entry nothing uses is
    # surface, and this is the layer whose whole job is to have less of it.
    "/twirp/github.actions.results.api.v1.ArtifactService/*"
    "/*/*/info/refs"
    "/*/*/git-upload-pack"
  ];

  # EVERY SITE IS RATE-LIMITED unless it opts out with `rateLimit = null`.
  # This was opt-in, and exactly one site (search) had opted in, which left
  # every login on music, mail and git open to guessing at whatever speed the
  # service itself allowed. The default has to be the limit.
  #
  # Up to three zones per site, all keyed on the client IP:
  #
  #   * SITE-WIDE — a flood brake. `rateLimit` overrides the numbers. Exempt:
  #     private ranges (every docker bridge, so kuma's probes and anything
  #     hairpinning through a bridge gateway), this host's own public address
  #     (renovate and pages-pull reach git.<domain> through it) and the CI
  #     runners (already confined to runnerApiPaths below, and a limit there
  #     only breaks CI). None of those is an attacker, and throttling them is
  #     a self-inflicted outage.
  #
  #   * BASIC AUTH — `basicAuthRateLimit`, for sites that take a password in
  #     an Authorization header rather than a form (git over https, the API).
  #     Exempt like the site-wide zone.
  #
  #   * LOGIN — `loginMatch`, a caddy matcher for the site's login request,
  #     always ANDed with `method POST`. Tight, and exempts NOBODY: nothing on
  #     this host posts to a login form, so a private address here can only be
  #     a real client whose address got masked on the way in, and then a shared
  #     bucket failing closed is the right answer.
  #
  # ponytail: the numbers are knobs set from how each app loads, not from
  # measured traffic. A 429 in normal use means raise that site's `rateLimit`.
  defaultRateLimit = {
    events = 300;
    window = "1m";
  };
  loginRateLimit = {
    events = 10;
    window = "1m";
  };
  rateLimitExempt = [
    "private_ranges"
    config.infra.publicIPv4
  ]
  ++ lib.attrValues runnerIPv4s;
  rateLimitOf = site: site.rateLimit or defaultRateLimit;

  # git.<domain> is served twice — publicly, and on the tailnet listener
  # with the admin paths open — so it is defined once, here.
  gitSite = {
    host = "git.${domain}";
    upstream = "forgejo:4242";

    # A repo page pulls a few dozen assets. Forgejo has no login throttle of
    # its own, so the login zone is the only one there is.
    rateLimit = {
      events = 600;
      window = "1m";
    };
    loginMatch = "path /user/login /user/two_factor* /user/forgot_password /user/sign_up";

    # The logins that are NOT a form: `git clone https://user:pass@...` and
    # /api/v1 with basic auth both send `Authorization: Basic` and never
    # touch /user/login, so the login zone above cannot see them. A git
    # operation is 2-4 requests, so 30 a minute is room for real use and
    # nowhere near a guessing rate. Exempt like the site-wide zone: renovate
    # pushes over https with its token as a basic-auth password, from this
    # host's own address.
    basicAuthRateLimit = {
      events = 30;
      window = "1m";
    };

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

    # SITE ADMINISTRATION, closed to the internet and served only on the
    # tailnet copy below. /admin is the web admin panel (users, orgs, every
    # repo, instance config, cron, system webhooks); /api/v1/admin/* is its
    # API, 34 endpoints on 16.0.5, every one site-admin only. Nothing here
    # automates against them — the runner registers with a pre-shared token,
    # and the pages system webhook is set once by hand. Personal settings
    # (/user/settings, /api/v1/user/*) and org settings stay public.
    #
    # A stolen password or session can then still read and push what the
    # account owns, but it cannot create users, mint runner tokens or rewrite
    # instance config from outside the tailnet.
    blockedPaths = [
      "/admin"
      "/admin/*"
      "/api/v1/admin"
      "/api/v1/admin/*"
    ];
  };

  sites = [
    {
      host = "music.${domain}";
      upstream = "navidrome:4533";

      # Subsonic clients authenticate on EVERY /rest/ call and a library sync
      # is thousands of them, so the site-wide brake sits high. The Subsonic
      # brute-force fix is navidrome's own (0.64.1 throttles failed logins);
      # this caps the web UI's login.
      rateLimit = {
        events = 1200;
        window = "1m";
      };
      loginMatch = "path /auth/login";
    }
    {
      host = "mail.${domain}";
      upstream = "webmail:80";

      # Roundcube's login form posts to `/?_task=login`. Roundcube also locks
      # an account after 3 failures a minute (login_rate_limit), but only per
      # account and only for accounts it has seen; this is per address.
      loginMatch = "query _task=login";
    }
    gitSite
    {
      host = "status.${domain}";
      upstream = "kuma:3001";

      # The public status page never opens socket.io — kuma 2.5.5 lists
      # /status* and / in noSocketIOPages and loads everything over
      # /api/status-page/* — so /socket.io/ is ONLY the admin login and
      # dashboard. It is closed here, and open on the tailnet copy of this
      # same name further down.
      #
      # A rate limit could not do this job: kuma's login is a message INSIDE
      # an open websocket, so caddy sees one request however many passwords go
      # through it. kuma's own limiter (20 a minute) is then the only layer,
      # and one bad line there is a brute-force hole. Not exposing the socket
      # at all is the layer that cannot be one line away from failing.
      blockedPaths = [ "/socket.io/*" ];
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

      # Lower than the default: the site-wide zone returns 429 BEFORE
      # basic_auth runs its bcrypt (see the global `order` below), so a
      # password flood cannot turn cost-14 verifications into CPU exhaustion.
      # In-process: a misconfig throttles requests, it cannot take the box
      # down the way the forward-chain fail2ban jail did.
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
      # status.<domain> AGAIN, on the tailnet listener and with /socket.io/
      # open: kuma's admin dashboard and login, for tailnet devices only. The
      # public name resolves to the public address, so a tailnet device only
      # lands here if its resolver hands it the tailnet address for this name.
      host = "status.${domain}";
      upstream = "kuma:3001";
      tailnet = true;
    }
    # git.<domain> AGAIN, on the tailnet listener, with the site-admin paths
    # open. Same limits. No runner restriction: the runner is deliberately off
    # the tailnet (modules/runner/networking.nix), and the tailnet policy
    # grants this host to the owner's account alone.
    (
      builtins.removeAttrs gitSite [
        "blockedPaths"
        "restrictRunners"
      ]
      // {
        tailnet = true;
      }
    )
    {
      host = "grafana.${domain}";

      # A dashboard is one request per panel per refresh.
      rateLimit = {
        events = 1200;
        window = "1m";
      };

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

      # The GUI polls several REST endpoints every few seconds.
      rateLimit = {
        events = 1200;
        window = "1m";
      };

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

  anyRateLimit = lib.any (s: rateLimitOf s != null || s ? loginMatch) sites;

  tailnetSites = lib.filter (s: s.tailnet or false) sites;

  # status.<domain> is served on both listeners, and rate-limit zones are
  # named per site, so the tailnet copy's zones carry a suffix.
  zoneName = site: site.host + lib.optionalString (site.tailnet or false) "-tailnet";

  # HALF-PUBLIC NAMES: served on both listeners, public and tailnet. The
  # tailnet-only names (dozzle, grafana, syncthing) need nothing special —
  # their public A record already points at the tailnet address, which only
  # the tailnet can reach. These cannot: the internet must keep getting the
  # public address. So tailnet devices are handed the tailnet address by
  # Tailscale split DNS (tofu/tailscale.tf), which asks the resolver below.
  #
  # Computed, not listed: give a site a tailnet copy and its name joins.
  # tofu's var.split_dns_subdomains must agree with this list.
  splitDnsHosts = lib.intersectLists (map (s: s.host) tailnetSites) (
    map (s: s.host) (lib.filter (s: !(s.tailnet or false)) sites)
  );
  inherit (config.infra) tailnetIPv4;

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
      # rate_limit is an ordered HTTP handler from a plugin, and it must run
      # before basic_auth or the 429 would come only after the bcrypt it exists
      # to save. Emitted only when a site actually uses it, which with the
      # opt-out default is whenever any site has not opted out.
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
          "${site.host}${lib.optionalString (site.tailnet or false) ":${toString tailnetHttpsPort}"} {"
          "\ttls ${certDir}/fullchain.pem ${certDir}/key.pem"
          "\theader ${hsts}"
        ]
        # HTTP/3 ON THE TAILNET, ADVERTISED ON 443. caddy fills Alt-Svc from
        # the LISTENER's port, so the tailnet sites would say h3=":8443". udp
        # 8443 sent directly over the tailnet does not get through — measured
        # after the deploy that published it, while tcp 8443 direct and udp
        # 443 redirected by the firewall both did — and a browser following
        # that advertisement hung exactly as before. 443 is also the port
        # every tailnet client already uses for these names, so the
        # advertisement names the path that works.
        ++ lib.optionals (site.tailnet or false) [
          "\theader Alt-Svc \"h3=\\\":443\\\"; ma=2592000\""
        ]
        # Zones keyed on {remote_host} — the client IP — so one address's flood
        # cannot exhaust the budget for everyone. Zone names start with the
        # host, so every site keeps separate counters. See `defaultRateLimit`
        # for what each zone is for and who is exempt.
        ++ lib.optionals (rateLimitOf site != null || site ? loginMatch) (
          [ "\trate_limit {" ]
          ++ lib.optionals (rateLimitOf site != null) [
            "\t\tzone ${zoneName site} {"
            "\t\t\tmatch {"
            "\t\t\t\tnot remote_ip ${lib.concatStringsSep " " rateLimitExempt}"
            "\t\t\t}"
            "\t\t\tkey {remote_host}"
            "\t\t\tevents ${toString (rateLimitOf site).events}"
            "\t\t\twindow ${(rateLimitOf site).window}"
            "\t\t}"
          ]
          ++ lib.optionals (site ? basicAuthRateLimit) [
            "\t\tzone ${zoneName site}-basic {"
            "\t\t\tmatch {"
            "\t\t\t\theader Authorization \"Basic *\""
            "\t\t\t\tnot remote_ip ${lib.concatStringsSep " " rateLimitExempt}"
            "\t\t\t}"
            "\t\t\tkey {remote_host}"
            "\t\t\tevents ${toString site.basicAuthRateLimit.events}"
            "\t\t\twindow ${site.basicAuthRateLimit.window}"
            "\t\t}"
          ]
          ++ lib.optionals (site ? loginMatch) [
            "\t\tzone ${zoneName site}-login {"
            "\t\t\tmatch {"
            "\t\t\t\tmethod POST"
            "\t\t\t\t${site.loginMatch}"
            "\t\t\t}"
            "\t\t\tkey {remote_host}"
            "\t\t\tevents ${toString loginRateLimit.events}"
            "\t\t\twindow ${loginRateLimit.window}"
            "\t\t}"
          ]
          ++ [ "\t}" ]
        )
        # Response headers, each entry scoped to a path matcher. `header` is an
        # ordered handler with a default position, so unlike rate_limit it
        # needs no `order` line in the global block.
        ++ lib.concatMap (
          h:
          [ "\theader ${h.path} {" ]
          ++ lib.mapAttrsToList (name: value: "\t\t${name} \"${value}\"") h.values
          ++ [ "\t}" ]
        ) (site.headers or [ ])
        # A `handle` of its own, NOT a bare `respond`: caddy orders `handle`
        # before `respond`, so on git.<domain> — whose upstream sits inside
        # handle blocks for restrictRunners — a bare respond would never run
        # and block nothing. Emitted before those handles, and named-matcher
        # handles keep their written order, so this one is tried first. 404
        # rather than 403: nothing to see here.
        ++ lib.optionals (site ? blockedPaths) [
          "\t@blocked path ${lib.concatStringsSep " " site.blockedPaths}"
          "\thandle @blocked {"
          "\t\trespond 404"
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
      # HTTP/3 on the tailnet listener. The firewall redirects tailscale0's
      # udp 443 here, and the tailnet sites advertise `h3=":443"` (see the
      # Alt-Svc override above), so every tailnet client takes that path —
      # including a browser still holding the public listener's `h3=":443"`.
      # Kept private like its tcp twin: in neither allow-list.
      "${toString tailnetHttpsPort}:${toString tailnetHttpsPort}/udp"
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

  # THE SPLIT-DNS RESOLVER. Answers exactly the half-public names with the
  # tailnet address and nothing else: any other name is outside its zone and
  # gets REFUSED, and an AAAA for these names is an empty answer (neither has
  # a public AAAA either). Bound to the tailnet address alone, so the internet
  # cannot even reach it; the input chain would drop 53 anyway. The tailnet
  # policy has to allow 53 to this host (tofu/tailscale-policy.hujson).
  #
  # IF IT IS DOWN, tailnet devices most likely cannot resolve these two names
  # at all: split DNS sends them ONLY here, and Tailscale documents no
  # fallback. The internet is unaffected, and both names are served by this
  # same box anyway, so the case that matters is CoreDNS alone failing —
  # Restart=on-failure (from the upstream module) covers it. Deploy this
  # before `tofu apply` points the tailnet at it.
  services.coredns = {
    enable = true;
    config = ''
      ${lib.concatStringsSep " " splitDnsHosts} {
        bind ${tailnetIPv4}
        hosts {
          ${tailnetIPv4} ${lib.concatStringsSep " " splitDnsHosts}
          ttl 300
        }
      }
    '';
  };

  # The address exists only once tailscaled has brought tailscale0 up, and a
  # bind to an absent address fails. Wait for it rather than crash-looping
  # through boot. 60 seconds, under systemd's default 90-second start timeout,
  # which counts ExecStartPre. Matched as "inet <addr>/" so 100.109.115.120
  # cannot satisfy a wait for 100.109.115.12.
  systemd.services.coredns = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig.ExecStartPre = "${pkgs.writeShellScript "wait-for-tailnet-address" ''
      for _ in $(${pkgs.coreutils}/bin/seq 60); do
        ${pkgs.iproute2}/bin/ip -4 addr show dev tailscale0 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -qF "inet ${tailnetIPv4}/" && exit 0
        ${pkgs.coreutils}/bin/sleep 1
      done
      echo "tailscale0 never got ${tailnetIPv4}" >&2
      exit 1
    ''}";
  };

  # acme writes the certificate before anything can serve it. Without this a
  # first boot starts caddy against an empty directory and it exits.
  systemd.services.docker-caddy = {
    after = [ "acme-${domain}.service" ];
    wants = [ "acme-${domain}.service" ];
  };
}
