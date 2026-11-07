# ==============================================================================
# Anubis — proof-of-work gate in front of the public sites
# ==============================================================================
# Publishes no port. Caddy asks it about every request to a public site (see
# `forward_auth` in modules/containers/caddy.nix) and serves its challenge page
# at /.within.website/ on each of them.
#
# WHY: on 2026-11-07 a scraper swarm walked every commit and /archive/ link on
# git.<domain> from hundreds of addresses at ~6 req/s, a few requests each, and
# Forgejo went from 2 GB to 5 GB of RAM. The per-IP rate limit cannot see a
# flood spread that thin; a challenge that costs each new client a browser and
# some CPU can.
#
# SUBREQUEST MODE (`TARGET=" "`): one instance answers "pass or challenge" for
# every host and proxies nothing itself. The alternative is one Anubis per
# upstream sitting in the request path, which is a container per site.
#
# The signing key is generated at start, so a restart re-challenges everyone
# once. ponytail: ephemeral key; put ED25519_PRIVATE_KEY_HEX in sops if that
# ever becomes annoying.
{ config, pkgs, ... }:

let
  inherit (config.infra) domain proxyNetwork;

  # The stock policy, plus two changes.
  #
  # NON-BROWSERS ARE CHALLENGED TOO. Stock Anubis only weighs user agents that
  # claim to be a browser and lets everything else through, so a scraper gets
  # past by sending `User-Agent: curl`. Here anything that is not a browser
  # gets the same +10 a browser does (and so the same challenge) everywhere
  # EXCEPT the paths real tools use, which a challenge would simply break:
  #
  #   /api/, /v2/                     Forgejo's API, the container registry
  #   info/refs, git-*-pack           git over https (clone, fetch, push)
  #   .git/info/lfs/                  git LFS
  #   /releases/download/             release assets fetched by curl/wget
  #   .rss, .atom                     feed readers
  #   ?go-get=1                       `go get` resolving a module path
  #
  # BEHIND forward_auth, ANUBIS'S `path` IS THE URI WITH ITS QUERY. So the
  # ends are `(\?|$)`, not `$`, or `/info/refs?service=git-upload-pack`
  # (every clone's first request) never matches; and every match is pinned to
  # `^[^?]*`, or `/any/page?x=/info/refs` walks past the challenge.
  #
  # The stock allow rules (/.well-known/, /robots.txt, favicon, sitemap and
  # verified search crawlers) still come first and still win. What stays
  # challenged for a non-browser: every web page, /raw/ and /media/ included.
  #
  # DENY must not be 200. In subrequest mode the check endpoint's status IS
  # the verdict, and caddy's forward_auth lets any 2xx through, so the default
  # DENY=200 would wave every denied bot past. CHALLENGE never reaches
  # forward_auth as a page (the check answers 401 for it), so its code only
  # applies to the challenge page itself.
  policy = pkgs.writeText "anubis-policy.yaml" ''
    bots:
      - import: (data)/meta/default-config.yaml
      - name: non-browser-off-the-tool-paths
        action: WEIGH
        expression:
          all:
            - '!userAgent.matches("Mozilla|Opera")'
            - '!path.matches("^/(api|v2)/|^[^?]*(/info/refs|/git-(upload|receive)-pack|\\.rss|\\.atom)(\\?|$)|^[^?]*(\\.git/info/lfs|/releases/download)/")'
            - '!("go-get" in query)'
        weight:
          adjust: 10
    status_codes:
      CHALLENGE: 200
      DENY: 403
  '';

  # nixpkgs' build rather than the upstream image, like caddy: the version
  # moves with the flake and there is no digest to keep up with.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "anubis";
    tag = pkgs.anubis.version;
    config.Entrypoint = [ "${pkgs.anubis}/bin/anubis" ];
  };
in
{
  virtualisation.oci-containers.containers.anubis = {
    image = "anubis:${pkgs.anubis.version}";
    imageFile = image;

    # Joined so caddy can resolve `anubis`. Anubis itself talks to nothing.
    networks = [ proxyNetwork ];

    environment = {
      BIND = ":8923";
      TARGET = " ";
      POLICY_FNAME = "/etc/anubis/policy.yaml";
      # Only ever bounce a passed challenge back to one of our own names.
      REDIRECT_DOMAINS = "*.${domain}";
    };

    volumes = [ "${policy}:/etc/anubis/policy.yaml:ro" ];

    # Holds nothing on disk (the default store is in memory), so it needs no
    # writable path and no identity of its own.
    extraOptions = [
      "--user=65534:65534"
      "--read-only"
      "--security-opt=no-new-privileges:true"
      "--cap-drop=ALL"
    ];
  };
}
