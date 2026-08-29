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
  net = config.infra.proxyNetwork;
  cfg = config.virtualisation.oci-containers;
in
{
  imports = [
    ./caddy.nix
    ./cloudflared.nix
    ./dozzle.nix
    ./forgejo.nix
    ./grafana.nix
    ./kuma.nix
    ./mailserver.nix
    ./minecraft.nix
    ./navidrome.nix
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

  systemd.services = {
    # Every container that talks to caddy joins this network, and nothing
    # else creates it. compose declared it `external: true` and
    # docker-services.sh made it; here it is a unit the containers require,
    # so a container can never start onto a network that does not exist yet.
    "docker-network-${net}" = {
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
      script = ''
        docker network inspect ${net} >/dev/null 2>&1 \
          || docker network create ${net}
      '';
    };
  }
  // lib.mapAttrs' (
    name: container:
    lib.nameValuePair "docker-${name}" (
      {
        serviceConfig = {
          # The module defaults to on-failure, which leaves a container that
          # exited 0 stopped until someone notices. compose's
          # `restart: unless-stopped` is this.
          Restart = lib.mkForce "always";
          RestartSec = 5;
        };
      }
      // lib.optionalAttrs (lib.elem net container.networks) {
        after = [ "docker-network-${net}.service" ];
        requires = [ "docker-network-${net}.service" ];
      }
    )
  ) cfg.containers;
}
