# ==============================================================================
# Containers — shared plumbing
# ==============================================================================
# Ported from ansible/roles/services/* in the infra repo. Three layers collapse
# into one here: docker's restart policy, the boot-time `docker-services.sh`
# sweep and ansible's own converge are all just systemd units now, so a
# container that does not exist is created at boot by the same mechanism that
# restarts one that died.
#
# Two deliberate departures from the compose files this replaces:
#
#   * Data lives in named docker volumes, never in a bind-mounted host
#     directory. `services.restic` backs up /var/lib/docker/volumes wholesale,
#     so a new service is covered by the backup the moment it declares a
#     volume — nothing to remember to add to a path list.
#
#   * Configuration files come from the Nix store, read-only. They are
#     world-readable (0444), which is what the tempo (uid 10001) and grafana
#     (uid 472) permission failures in the ansible setup were about, and their
#     store path changes when their content does — so systemd recreates the
#     container on a config-only change, which is what `recreate: always` was
#     working around.
{
  config,
  lib,
  ...
}:

let
  cfg = config.virtualisation.oci-containers;

  # Network name -> extra `docker network create` arguments.
  #
  # An attrset rather than two near-identical units, because the per-container
  # ordering below has to be derived from the SAME set of names. When this was a
  # single hardcoded unit for `proxy`, the ordering was a `lib.elem net
  # container.networks` special case — and a container joining any second
  # network would have started with no dependency on the unit that creates it.
  # That race fails intermittently at boot, which is the worst shape a bug can
  # take here.
  networks = {
    # Left to docker's address pool: nothing names an address on it, because
    # caddy resolves its upstreams by container name over the embedded DNS.
    ${config.infra.proxyNetwork} = [ ];

    # Pinned, because `infra.botGateway` is a literal in the bot's DATABASE_URL
    # and OTLP endpoint and in the firewall's input rule. See modules/options.nix.
    ${config.infra.botNetwork} = [
      "--subnet=${config.infra.botSubnet}"
      "--gateway=${config.infra.botGateway}"
    ];
  };
in
{
  imports = [
    ./caddy.nix
    ./cloudflared.nix
    ./dozzle.nix
    ./forgejo.nix
    ./forgejo-runner.nix
    ./grafana.nix
    ./kuma.nix
    ./mailserver.nix
    ./minecraft.nix
    ./navidrome.nix
    ./searxng.nix
    ./serenity-bot.nix
    ./tempo.nix
  ];

  virtualisation = {
    oci-containers.backend = "docker";

    # Container logs are NOT configured here on purpose: oci-containers already
    # defaults every container to the journald driver, so journald's own limits
    # do the rotating and `journalctl -u docker-<name>` is the way to read them.
    # A json-file default would put unbounded logs back on the disk and break
    # the forgejo fail2ban jail, which reads the journal.

    # Images are pinned to release tags, so a dangling layer left behind by a
    # bump is dead weight rather than something to keep. Volumes are never
    # touched: `docker system prune` without --volumes cannot delete data.
    docker.autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  systemd.services =
    # Nothing else creates these networks. compose declared `external: true` and
    # docker-services.sh made them; here each is a unit the containers require,
    # so a container can never start onto a network that does not exist yet.
    lib.mapAttrs' (
      net: createArgs:
      lib.nameValuePair "docker-network-${net}" {
        description = "Create the ${net} docker network";
        wantedBy = [ "multi-user.target" ];
        after = [
          "docker.service"
          "docker.socket"
        ];
        requires = [ "docker.service" ];
        path = [ config.virtualisation.docker.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # Create-if-missing, so this is a no-op on every boot after the first.
        # An existing network is NOT reconciled against createArgs — changing a
        # pinned subnet means removing the network by hand, which is deliberate:
        # silently recreating it would detach every running container on it.
        script = ''
          docker network inspect ${net} >/dev/null 2>&1 \
            || docker network create ${lib.escapeShellArgs createArgs} ${net}
        '';
      }
    ) networks
    // lib.mapAttrs' (
      name: container:
      let
        # Only the networks THIS module creates. A container declaring some
        # other network (or none) gets no ordering, rather than a dependency on
        # a unit that does not exist.
        joined = lib.intersectLists (lib.attrNames networks) container.networks;
        units = map (net: "docker-network-${net}.service") joined;
      in
      lib.nameValuePair "docker-${name}" {
        serviceConfig = {
          # The module defaults to on-failure, which leaves a container that
          # exited 0 stopped until someone notices. compose's
          # `restart: unless-stopped` is this.
          Restart = lib.mkForce "always";
          RestartSec = 5;
        };
        after = units;
        requires = units;
      }
    ) cfg.containers;
}
