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
  pkgs,
  ...
}:

let
  cfg = config.virtualisation.oci-containers;
  docker = "${config.virtualisation.docker.package}/bin/docker";

  # Every image a container here names, running or not. Not running matters:
  # the worlds are deleted when they sleep, so docker sees their images as
  # unused, and a 1.2G re-pull on wake does not fit mc-router's wake timeout.
  keptImages = pkgs.writeText "kept-images" (
    lib.concatMapStrings (c: c.image + "\n") (lib.attrValues cfg.containers)
  );

  # Superseded versions are tagged, so the dangling-only prune below never
  # reaches them: every bump left its old image behind (~20G by 2026-10-25).
  # This removes every image the config does not name, matched by ID because
  # digest-pinned pulls carry no tag. `image rm` without -f refuses anything a
  # container still uses, so a deploy racing this costs a re-pull at worst.
  # Dry-run against the live box on 2026-10-25: all 17 configured images kept,
  # 43 superseded ones listed for removal.
  removeUnnamedImages = pkgs.writeShellScript "docker-remove-unnamed-images" ''
    set -u
    keep=""
    while IFS= read -r ref; do
      keep="$keep $(${docker} image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
    done < ${keptImages}

    # Something here is always running, so an empty list means docker did not
    # answer, not that nothing is in use. Removing on it would take everything.
    if [ -z "''${keep// /}" ]; then
      echo "docker-prune: no configured image resolved, removing nothing" >&2
      exit 1
    fi

    rc=0
    list() { ${docker} image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'; }
    remove() {
      echo "docker-prune: removing $1"
      ${docker} image rm "$1" || rc=1
    }

    # Tags first. Untagged entries can only be named by ID, and removing an ID
    # that a tag still references fails without -f; once its tags are gone, it
    # cannot.
    while read -r id ref; do
      case " $keep " in *" $id "*) continue ;; esac
      case "$ref" in *:"<none>") ;; *) remove "$ref" ;; esac
    done < <(list)

    # Then what is left untagged, from a fresh listing, once per ID.
    while read -r id; do
      case " $keep " in *" $id "*) continue ;; esac
      remove "$id"
    done < <(list | ${pkgs.gnugrep}/bin/grep ':<none>$' | ${pkgs.coreutils}/bin/cut -d' ' -f1 | ${pkgs.coreutils}/bin/sort -u)
    exit $rc
  '';

  # EVERY CONTAINER HAS A MEMORY CEILING, so one that runs away is OOM-killed
  # and restarted (Restart=always below) instead of the kernel picking a
  # victim on a box with no swap — which could be mail or a world mid-save.
  # Forgejo went from 2G to 5G in half an hour under a scraper swarm
  # (2026-11-07) with nothing in its way. A tmpfs's pages count against the
  # container's limit too.
  #
  # Roughly 3x what each used on 2026-11-08, with room for its known spikes
  # (forgejo packing a clone, navidrome scanning, tempo compacting). The worlds
  # and horizon set their own, next to the heap they size it from; the
  # assertion below fails the build for any container that has none.
  #
  # ponytail: ceilings, not reservations — they add up past 16G on purpose,
  # since nothing runs at its ceiling at once. A container that OOM-loops
  # in normal use means raise its number here.
  memoryLimits = {
    anubis = "512m";
    caddy = "512m";
    cloudflared = "256m";
    dozzle = "256m";
    forgejo = "2g";
    grafana = "2g";
    kuma = "512m";
    mailserver = "1g";
    mc-router = "128m";
    navidrome = "512m";
    pages-hook = "128m";
    searxng = "512m";
    serenity-bot-0 = "2g";
    serenity-redis = "256m";
    tempo = "1g";
    webmail = "512m";
  };

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
    # Pinned so caddy can have a fixed address (`infra.caddyIPv4`), which the
    # firewall DNATs tailnet traffic to. Upstreams are still resolved by name;
    # caddy is the only container with a pinned address. Pinning it meant
    # recreating the network by hand once (#43, docs/src/operations/deploying.md).
    ${config.infra.proxyNetwork} = [
      "--subnet=${config.infra.proxySubnet}"
      "--gateway=${config.infra.proxyGateway}"
      "--ip-range=${config.infra.proxyIpRange}"
    ];

    # Pinned, because `infra.botGateway` is a literal in the bot's DATABASE_URL
    # and OTLP endpoint and in the firewall's input rule. See modules/options.nix.
    ${config.infra.botNetwork} = [
      "--subnet=${config.infra.botSubnet}"
      "--gateway=${config.infra.botGateway}"
    ];

    # Pinned for the same reason: the firewall and minecraft-scaler name
    # mc-router's address and the gateway. The worlds take their addresses
    # from mcIpRange, which leaves mcRouterAddress free: on the first deploy
    # the worlds started first, and world 1 was handed 172.31.0.2.
    ${config.infra.mcNetwork} = [
      "--subnet=${config.infra.mcSubnet}"
      "--gateway=${config.infra.mcGateway}"
      "--ip-range=${config.infra.mcIpRange}"
    ];
  };
in
{
  imports = [
    ./anubis.nix
    ./caddy.nix
    ./cloudflared.nix
    ./dozzle.nix
    ./forgejo.nix
    ./grafana.nix
    ./horizon.nix
    ./kuma.nix
    ./mailserver.nix
    ./mc-router.nix
    ./minecraft.nix
    ./navidrome.nix
    ./searxng.nix
    ./serenity-bot.nix
    ./tempo.nix
  ];

  assertions = lib.mapAttrsToList (name: c: {
    assertion = lib.any (lib.hasPrefix "--memory=") c.extraOptions;
    message = "container ${name} has no --memory limit; add it to memoryLimits in modules/containers/default.nix";
  }) cfg.containers;

  virtualisation = {
    oci-containers.backend = "docker";
    oci-containers.containers = lib.mapAttrs (_: limit: {
      extraOptions = [ "--memory=${limit}" ];
    }) memoryLimits;

    # Container logs are NOT configured here on purpose: oci-containers already
    # defaults every container to the journald driver, so journald's own limits
    # do the rotating and `journalctl -u docker-<name>` is the way to read them.
    # A json-file default would put unbounded logs back on the disk and break
    # the forgejo fail2ban jail, which reads the journal.

    # `flags` is deliberately empty, so this is a plain `docker system prune`:
    # DANGLING LAYERS ONLY. It is not `--all`, which would take the sleeping
    # worlds' images. Old versions are removed by removeUnnamedImages, which
    # runs first in the same unit. Volumes are never touched either: without
    # --volumes, prune cannot delete data.
    #
    # The runner's podman prune IS `--all`, and it eats the locally built job
    # image; see modules/runner/ci-image.nix.
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
    ) cfg.containers
    // {
      # First, so the layers it frees are dangling by the time prune runs.
      docker-prune.serviceConfig.ExecStartPre = [ "${removeUnnamedImages}" ];
    };
}
