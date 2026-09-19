# ==============================================================================
# Shared infrastructure facts
# ==============================================================================
# Values that more than one module needs, in one place so they cannot drift.
#
# Everything here is PUBLIC. The Nix store is world-readable, so a secret must
# never become a Nix string — it reaches a container as a file or an env file at
# runtime instead. See modules/secrets.nix.
{ lib, ... }:

{
  options.infra = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "hu-tao.dev";
      description = ''
        Apex domain. The ACME certificate is named after it, and every
        `certSubdomains` entry is a SAN on that one certificate — so the
        certificate name, the path caddy reads and the path DMS reads all
        follow from this single value.
      '';
    };

    certSubdomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "smtp"
        "git"
        "mail"
        "music"
        "status"
        "search"
        "pages"
        # Tailnet-only vhosts. They belong on the same certificate as the rest
        # because DNS-01 never needs a name to resolve publicly or a port to be
        # reachable — see modules/containers/caddy.nix.
        "dozzle"
        "grafana"
        "syncthing"
      ];
      description = ''
        Subdomains carried as SANs on the apex certificate. Order is
        irrelevant here, unlike certbot: the certificate is named
        `infra.domain` explicitly, so reordering this list cannot silently
        issue a second lineage under a new name.
      '';
    };

    pagesVolume = lib.mkOption {
      type = lib.types.str;
      default = "pages_data";
      description = ''
        Docker volume holding the static sites served at `pages.<domain>`.
        Named here because three places must agree on it: caddy mounts it
        read-only, the Actions runner allows it as the ONE volume a workflow
        may mount, and a workflow names it in `jobs.<id>.container.volumes`.
        Being a docker volume also means restic already backs it up, since
        `services.restic` takes /var/lib/docker/volumes wholesale.
      '';
    };

    pagesRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "hutao/compress"
        "skavex/skavex"
      ];
      description = ''
        The repositories whose published pages are served at `pages.<domain>`,
        as `<owner>/<repo>`. Read by modules/pages-pull.nix, which fetches each
        one's newest artifact named `pages` and unpacks it into
        `<pagesVolume>/<owner>/<repo>` — the layout IS the URL, so this list is
        also the list of paths that answer under pages.<domain>.

        THE LIST EXISTS BECAUSE THE DIRECTION REVERSED. While the runner lived
        on this box a publishing workflow mounted the pages volume and wrote
        into it, so nothing here had to know which repos published; the set was
        whatever had ever run the job. A runner on its own box cannot reach this
        volume and must not, so the pull side has to be told what to look for.

        Defaulted to what the volume already held on 2026-09-19 rather than left
        empty: an empty list is a silently no-op timer, which is the failure
        this repo keeps writing comments about.

        `hutao/critical-forest` is deliberately NOT here even though the volume
        holds a tree for it: the repo 404s under both `hutao` and `skavex`, so
        it was renamed or deleted at some point and nothing can be pulled for
        it. The served tree is left in place — caddy keeps answering that path
        — but a name that cannot resolve would fail this unit every five
        minutes forever. A repo that genuinely disappears belongs out of this
        list, not permanently red in the journal.

        A repo listed here that has never uploaded a `pages` artifact is not an
        error — the unit logs "no live pages artifact" and leaves any existing
        tree alone, which is also exactly what it does for a repo whose
        artifacts have aged out.
      '';
    };

    publicIPv4 = lib.mkOption {
      type = lib.types.str;
      default = "167.233.24.58";
      description = ''
        The primary IPv4, as seen from the internet. Owned by tofu — it is an
        `hcloud_primary_ip` with delete protection, deliberately separate from
        the server so an IP handover carries mail reputation to a new box with
        no DNS change. This is a COPY of that value for the things NixOS needs
        it for, not the source of truth; if it ever changes, tofu changes it
        first and this follows.

        Public by definition, so a plain string is right — the reasoning on
        `acmeEmail` applies here too.
      '';
    };

    runnerIPv4s = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        forgejo-runner = "46.225.61.172";
      };
      description = ''
        The CI runners' public IPv4s. Consumed by modules/firewall.nix, which
        emits one `ip daddr <addr> tcp dport 22 ct state new accept` per entry
        into the OUTPUT chain: that chain is policy-drop, so `ssh -J vps
        root@<runner>` -- the runners' only admin path, since they are
        deliberately off the tailnet -- does not leave this box without it.

        KEYED BY HETZNER SERVER NAME, matching tofu's var.runner_ipv4s. An
        attrset rather than a list because an address on its own says nothing
        about which box it belongs to, and a bare list invites being correlated
        by index with some other list — which stays silently wrong when an
        entry is removed from the middle. Rules are emitted in key order, so
        the rendered ruleset does not churn when an entry is added.

        Adding a runner means an entry here AND one in tofu's
        var.runner_ipv4s: the cloud firewall and this ruleset are each what
        survives a misconfiguration of the other, so a rule in one alone is not
        sufficient.

        Bare addresses, not CIDRs. nftables `ip daddr` takes either, and
        keeping the two spellings distinct makes it obvious at a glance which
        list a value was copied from.

        Owned by tofu and copied here, same as publicIPv4: if an address
        changes, tofu changes first and this follows. A runner's address
        changes whenever its box is replaced, which `user_data` being
        replace-forces-new means happens on every identity rotation.
      '';
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "ivan@hu-tao.org";
      description = ''
        ACME account contact. A plain string rather than a sops secret because
        `security.acme` needs it at evaluation time — and a registration
        contact address is not a credential.
      '';
    };

    proxyNetwork = lib.mkOption {
      type = lib.types.str;
      default = "proxy";
      description = ''
        Docker network caddy shares with everything it reverse-proxies.
        Upstreams are container names resolved by docker's embedded DNS on
        this network, which is why the Caddyfile names no IP addresses.
      '';
    };

    tailnetHttpsPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = ''
        Caddy's SECOND https listener, carrying the vhosts that are meant for
        the tailnet alone — dozzle, grafana and syncthing. Two places must
        agree on it: caddy publishes it, and the firewall's prerouting chain
        rewrites tailscale0's port 443 onto it, which is what lets the URL be
        `https://dozzle.<domain>` with no port in it.

        It is published on 0.0.0.0 like every other container port and kept
        private exactly the way grafana:3000 is — by its ABSENCE from the
        firewall's public allow-lists, not by a bind address.
      '';
    };

    tailnetHttpPort = lib.mkOption {
      type = lib.types.port;
      default = 8880;
      description = ''
        The plain-http half of `tailnetHttpsPort`, serving nothing but a
        redirect to https.

        It exists because a site address with an explicit port makes caddy skip
        the http->https redirect it adds for every other site. Without it a
        browser that still tries http first lands on the PUBLIC :80 listener,
        which has no site for these names and answers 404 — the confusing
        failure, not the obvious one.
      '';
    };

    cacheProxyPort = lib.mkOption {
      type = lib.types.port;
      default = 34567;
      description = ''
        The Actions cache proxy port, shared by the two things that must agree
        on it and would otherwise only agree by comment: the runner's own
        `cache.proxy_port` (modules/runner/default.nix — job containers reach
        the cache here via ACTIONS_CACHE_URL), and the runner's firewall
        (modules/runner/firewall.nix — an input rule has to admit exactly this
        port from the podman bridges).

        Fixed rather than left at the runner's default (random), because a
        firewall rule cannot name a port the daemon chooses at startup. Same
        number as the VPS runner's cache port, so it means the same thing on
        both boxes.
      '';
    };

    botNetwork = lib.mkOption {
      type = lib.types.str;
      default = "botnet";
      description = ''
        Docker network for the discord bot and the redis it caches in. Separate
        from `proxyNetwork` because the bot serves nothing and has no business
        being reachable from caddy — it is an outbound gateway client.
      '';
    };

    botSubnet = lib.mkOption {
      type = lib.types.str;
      default = "172.30.0.0/24";
      description = ''
        Subnet pinned onto `botNetwork` at creation, rather than left to
        docker's address pool. Two things depend on it being fixed: the
        firewall's input rule names it as a source, and `botGateway` is a
        literal that would go stale if docker were free to renumber the bridge.
      '';
    };

    botGateway = lib.mkOption {
      type = lib.types.str;
      default = "172.30.0.1";
      description = ''
        The host's address on `botNetwork`, i.e. how a container on it reaches
        services in the host's own network namespace — postgres via pgbouncer,
        and tempo's OTLP receiver.

        MUST be the first usable address of `botSubnet`. It is passed to
        `docker network create --gateway` explicitly rather than relying on
        docker picking the first address, so the two can only disagree if this
        pair is edited inconsistently.
      '';
    };

    dockerBridgeGateway = lib.mkOption {
      type = lib.types.str;
      default = "172.17.0.1";
      description = ''
        The host's address on docker's DEFAULT bridge, and the one address a
        job container can reach the host at whichever per-job network it was
        created on — `container.network` is "" (see
        modules/containers/forgejo-runner.nix), so that network differs every
        run and its own gateway cannot be named ahead of time. The Actions
        cache proxy is published here.

        Caddy uses it too, for the two tailnet vhosts whose backends are in the
        HOST's network namespace rather than on the proxy network: grafana:3000
        and syncthing's GUI:8384. A container on any bridge reaches a local
        address of the host by routing through its own gateway, so this works
        from the proxy network as well.

        OBSERVED, not enforced. `ip -4 -br addr show docker0` reports
        172.17.0.1/16 on this host, which is docker's built-in default.

        Deliberately NOT pinned with the daemon's `bip` setting, even though
        pinning is what `botSubnet`/`botGateway` do for a network this repo
        creates itself. `bip` is daemon config, so setting it restarts
        docker.service, which stops EVERY container — and the Actions runner
        comes back before caddy does, cannot reach https://git.''${domain}/ to
        declare itself, and exits 1. That is what took generation 54 down; see
        the revert of #9. A wrong value here costs one failed container start
        and a rollback. Pinning it costs a full container restart on the box,
        every deploy that touches this line.
      '';
    };
  };
}
