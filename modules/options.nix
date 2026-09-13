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

    dockerBridgeSubnet = lib.mkOption {
      type = lib.types.str;
      default = "172.17.0.1/16";
      description = ''
        Docker's DEFAULT bridge (docker0), pinned through the daemon's `bip`
        setting rather than left implicit. This is already docker's built-in
        default, so pinning it renumbers nothing — it only stops the value
        being an assumption.

        It has to stop being an assumption because the Actions runner publishes
        its cache proxy onto `dockerBridgeGateway`. A published port bound to
        an address the host does not own fails at container start, so a silent
        change in docker's default would take the runner down rather than
        merely mis-route it.
      '';
    };

    dockerBridgeGateway = lib.mkOption {
      type = lib.types.str;
      default = "172.17.0.1";
      description = ''
        The host's address on docker's default bridge, and the one address a
        job container can reach the host at whichever per-job network it was
        created on — `container.network` is "" (see
        modules/containers/forgejo-runner.nix), so that network differs every
        run and its own gateway cannot be named ahead of time.

        MUST be the address part of `dockerBridgeSubnet`. The Actions cache
        proxy is published here and nowhere else — not because 0.0.0.0 would
        expose it (modules/firewall.nix drops it: the forward chain is
        policy-drop and 34567 is not in its public allow-list) but because a
        host-local bind does not depend on that allow-list staying correct.
        That chain is edited whenever a service is published; this is not.
      '';
    };
  };
}
