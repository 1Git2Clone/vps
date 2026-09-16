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
