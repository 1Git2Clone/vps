# ==============================================================================
# The CI runner — podman and the Actions daemon
# ==============================================================================
# The runner is an ORDINARY SYSTEMD SERVICE. On the VPS it was an oci-container
# with /var/run/docker.sock bind-mounted in, and that socket — root on a box
# serving mail, git and every sops secret — is the whole reason this host
# exists. On a dedicated machine there is nothing to isolate the daemon from,
# so the container bought nothing and cost the mount.
#
# PODMAN, NOT DOCKER, and not as a preference: docker's nftables integration is
# what produced the half-working published ports and the forward-chain traps
# documented at length in modules/firewall.nix. Jobs still get a working
# `docker` command — dockerCompat installs the alias binary and dockerSocket
# puts /run/docker.sock in front of podman's — so a workflow that shells out to
# docker needs no edit.
#
# THE JOB-SIDE SOCKET IS DELIBERATE. container.docker_host below is podman's
# socket, which is exactly the access the VPS runner's valid_volumes allow-list
# and `docker_host: "-"` existed to DENY. That is not a relaxation of the old
# position; it is the same position at a different blast radius. A workflow
# that escapes here gets root on a machine holding a nix store, a job cache and
# its own runner token — no mail, no git, no sops key — and the box is a
# snapshot away from replacement. The isolation boundary moved from the
# container to the VM, which is what the second VM was for.
#
# NOT services.gitea-actions-runner. That module's ExecStartPre calls
# `forgejo-runner register`, and register is DEPRECATED upstream — run
# `forgejo-runner register --help` against the package in this flake and it
# says so in the first line. The current mechanism is a DECLARED runner: a
# uuid+secret pair Forgejo issues for one record, written into
# `server.connections` in config.yaml, with no imperative first-boot call and
# no `.runner` state file. The VPS's in-container runner (removed once this
# host took over) already did
# this correctly for the VPS's one permanent runner. The wrinkle here is that
# this box is a SNAPSHOT cloned into N runners, so the uuid can no longer be a
# Nix string the way it is there — every clone would otherwise claim the same
# runner record, which is undefined. See modules/runner/identity.nix, which is
# where the per-instance half of config.yaml gets composed.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # infra.cacheProxyPort (modules/options.nix), not a local literal: this file
  # and modules/runner/firewall.nix both have to agree on the number, and a
  # shared option is what makes that agreement structural instead of a
  # comment two files hope stays in sync.
  cacheProxyPort = config.infra.cacheProxyPort;

  # Where the runner lives and works. Not a Nix store path: identity.nix has to
  # write two things here at runtime — the composed config.yaml and the secret
  # file token_url points at — and a store path is world-readable, which is
  # exactly what a secret must never be. StateDirectory below is what makes
  # systemd agree this path exists and is owned by runnerUser before the
  # daemon starts; identity.nix creates and chowns it itself too, because it
  # has to run BEFORE that — see its header for why.
  stateDir = "/var/lib/forgejo-runner";

  # The composed config the daemon actually reads. Assembled by
  # identity.nix at runtime, not here — see the note on `runnerConfig` below.
  composedConfig = "${stateDir}/config.yaml";

  # A plain system user, not DynamicUser. Upstream's gitea-actions-runner used
  # DynamicUser=true with SupplementaryGroups=["podman"], which works for it
  # because upstream's ExecStartPre runs AS that unit and can write its own
  # state after the dynamic uid is allocated. Here the uuid+secret pair has to
  # be written by a SEPARATE unit that runs BEFORE this one starts (see
  # identity.nix) — and a dynamic uid does not exist until the unit it belongs
  # to starts, so there is no stable owner to chown the composed config to
  # ahead of time. A static system user has a uid fixed at activation, which is
  # what lets identity.nix hand the daemon files it can actually read.
  runnerUser = "forgejo-runner";
  runnerGroup = "forgejo-runner";

  # Assembled line by line rather than as one indented string: a multi-line
  # interpolation only indents its first line, and YAML is whitespace. Same
  # technique as the VPS's former in-container runner used.
  #
  # THIS IS THE STATIC HALF ONLY. There is no `server:` key here on purpose —
  # that section holds the uuid Forgejo issued for THIS runner's record, and
  # every clone of this snapshot gets a different one, so it cannot be baked
  # into a value every clone shares. modules/runner/identity.nix writes that
  # section at runtime, into ${composedConfig}, by putting it ahead of this
  # file's contents. Splitting it this way means the parts that ARE the same
  # across every clone (capacity, cache, the container engine settings) still
  # get Nix's evaluation-time checking, and only the part that truly differs
  # per instance is handled imperatively.
  runnerConfig = pkgs.writeText "forgejo-runner-config-static.yaml" (
    lib.concatStringsSep "\n" [
      "# Generated by Nix — edit modules/runner/default.nix"
      "# The `server:` section is NOT here — see modules/runner/identity.nix,"
      "# which prepends it onto this file at runtime."
      "log:"
      "  level: info"
      ""
      "runner:"
      # 4 vCPU at cx33, and nothing else on the box competing for them —
      # unlike the VPS, where this same 2 shared a machine with mail, git
      # and two JVMs.
      "  capacity: 2"
      "  timeout: 30m"
      ""
      "cache:"
      # Something needs it: serenity-discord-bot runs six compile jobs per
      # push, and a clean `cargo build --all-features` is 375s against 15s
      # with a warm target directory. Swatinem/rust-cache@v2 silently no-ops
      # when the runner sets no ACTIONS_CACHE_URL.
      "  enabled: true"
      # Inside the runner's own StateDirectory, so it survives a service
      # restart and gets picked up by whatever backs this box up.
      "  dir: ${stateDir}/cache"
      # Two ports, and only this one is reachable from outside the daemon.
      # `port` is the internal cache SERVER, left random on purpose;
      # proxy_port is what job containers connect to via ACTIONS_CACHE_URL,
      # so it has to be fixed for modules/runner/firewall.nix to name it.
      "  proxy_port: ${toString cacheProxyPort}"
      # `host` is deliberately ABSENT, not set to an empty string. Upstream
      # detects the outbound address automatically, which on this box is the
      # public IPv4 — the one address a job container can reach the host at
      # regardless of which per-job network it landed on (see
      # container.network below). Naming podman's default bridge instead
      # would depend on a bridge netavark creates lazily and a per-job
      # network never uses.
      ""
      "container:"
      # Empty, NOT "bridge". A per-job network, created and torn down with
      # the job, on which the runner registers each service under its
      # workflow name — which is what makes `services:` resolve. Per-job
      # rather than shared also matters at capacity 2: two concurrent jobs
      # both aliasing `postgres` on one network would round-robin between
      # each other's databases.
      "  network: \"\""
      "  privileged: false"
      # EMPTY. The VPS runner allow-lists exactly one volume — the pages
      # volume — and the pages volume does not exist on this box; caddy
      # serves it from the VPS.
      "  valid_volumes: []"
      # "-" MEANS MOUNT NO ENGINE SOCKET IN THE JOB CONTAINER, and it is what
      # makes a job EPHEMERAL. This is not the runner's own connection to the
      # engine (that is $DOCKER_HOST on the unit below, which still creates job
      # and service containers) — it is only what gets handed to the JOB.
      #
      # It was briefly podman's socket here, on the reasoning that a CI run
      # using docker should work. That reasoning had the cost backwards. Podman's
      # socket is root on this box: a job holding it can start a privileged
      # container mounting /, and from there write systemd units, the store, or
      # the runner's own identity pair. The job's container is destroyed when the
      # job ends; anything it plants on the HOST is not. So that one mount is the
      # difference between "a compromised job lasts one job" and "a compromised
      # job watches every later job on this runner and harvests its tokens".
      #
      # Without it a job's whole world is a container created for it and
      # destroyed after it, which is the property GitHub's hosted runners buy by
      # throwing away a VM per job. The remaining escape is a kernel or runtime
      # bug rather than a mount we handed over deliberately.
      #
      # THIS COSTS NOTHING TODAY. No workflow in any repo on this instance uses
      # docker in a job; checked across all six. `services:` does NOT need it —
      # hutao/serenity-discord-bot declares postgres and redis services and ran
      # them fine against the VPS runner, which also set "-", because the RUNNER
      # creates service containers, not the job. If a job ever genuinely needs a
      # container engine, the answer is dind as a service, not the host's socket.
      "  docker_host: \"-\""
    ]
    + "\n"
  );
in
{
  imports = [
    ./networking.nix
    ./users.nix
    ./identity.nix
    ./firewall.nix
  ];

  # ONE value crosses into identity.nix: the derivation for the static half of
  # config.yaml. Not modules/options.nix — this is wiring between two files in
  # this directory, not an infrastructure fact tofu or the VPS need. Everything
  # else identity.nix needs (the state dir, the user, the group) is a plain
  # string literal duplicated there instead, the same call modules/runner/
  # users.nix already makes for its ssh keys: a derivation has to come from
  # the code that builds it, a string is cheaper to duplicate than to plumb.
  options.runner.staticConfigFile = lib.mkOption {
    type = lib.types.path;
    internal = true;
    description = ''
      The STATIC half of config.yaml — everything except `server:`.
      identity.nix prepends the per-instance `server.connections` section
      onto this file at runtime to produce the file the daemon reads.
    '';
  };

  config = {
    runner.staticConfigFile = runnerConfig;

    users.users.${runnerUser} = {
      isSystemUser = true;
      group = runnerGroup;
      # podman, not docker: there is no docker on this host. Membership is
      # what lets the runner create job containers at all —
      # /run/podman/podman.sock is root:podman 0660, same reason the VPS
      # runner's oci-container passes `--group-add=docker`.
      extraGroups = [ "podman" ];
      home = stateDir;
      description = "Forgejo Actions runner daemon";
    };
    users.groups.${runnerGroup} = { };

    virtualisation.podman = {
      enable = true;

      # /run/docker.sock as a Symlink on podman.socket, whose SocketGroup is
      # `podman`. That group is created by the podman module itself whenever
      # virtualisation.podman.enable is true, so nothing here has to declare
      # it — which is the gid-goes-stale-silently failure the VPS runner's
      # --group-add comment warns about, avoided by construction.
      dockerSocket.enable = true;

      # The `docker` alias binary, so a workflow step that runs `docker build`
      # works unmodified. This was the requirement.
      dockerCompat = true;

      # 80 GB, and job images are the fastest-growing thing on it. Daily and
      # --all, because an image no job references is by definition not a warm
      # cache — the store and the Actions cache are what make a clone cheap,
      # and those are handled separately below.
      autoPrune = {
        enable = true;
        dates = "daily";
        flags = [ "--all" ];
      };

      # LOAD-BEARING, and the podman spelling of the lesson already written
      # into the VPS runner's `container.network: ""` comment above. A network
      # without embedded DNS makes a workflow's `services:` unresolvable, and
      # the failure is not an error but a wait loop burning the job's full
      # timeout.
      defaultNetwork.settings.dns_enabled = true;
    };

    # Harder than modules/nix.nix's weekly/30d, which is tuned for a box whose
    # store barely moves. This one builds every push: four job images, a nix
    # store that grows with every flake input, and an Actions cache.
    # mkForce because nix.nix sets both and the merge would otherwise be an
    # error on `dates` and a silent keep on `options`.
    nix = {
      gc = {
        dates = lib.mkForce "daily";
        options = lib.mkForce "--delete-older-than 7d";
      };
      optimise = {
        automatic = true;
        dates = [ "weekly" ];
      };
    };

    systemd.services.forgejo-runner = {
      description = "Forgejo Actions runner daemon";
      # requiredBy/before comes FROM identity.nix's forgejo-runner-identity
      # unit, not declared here — see its header for why the dependency edge
      # belongs on the unit that produces the file this one consumes, not the
      # other way round.
      wantedBy = [ "multi-user.target" ];
      after = [ "podman.service" ];
      wants = [ "podman.service" ];

      environment = {
        HOME = stateDir;
        # The runner's OWN connection to the engine, to create job containers
        # — distinct from `container.docker_host` in the config above, which
        # is what gets handed to each JOB. Explicit rather than relying on
        # dockerSocket's /run/docker.sock symlink resolving to the same place,
        # so this keeps working even if dockerCompat is ever turned off.
        DOCKER_HOST = "unix:///run/podman/podman.sock";
      };

      serviceConfig = {
        User = runnerUser;
        Group = runnerGroup;
        # Owned by runnerUser, created (if missing) before this unit's own
        # ExecStart — but identity.nix's oneshot runs BEFORE this unit and
        # cannot rely on that happening first, so it creates and chowns the
        # same path itself. Both agreeing on the owner is what makes that
        # safe: this declaration is not the only thing standing between the
        # daemon and a missing directory.
        StateDirectory = "forgejo-runner";
        WorkingDirectory = stateDir;

        Restart = "on-failure";
        RestartSec = 2;

        # Absolute path, config before the subcommand, same shape as the VPS
        # runner's container cmd. ${composedConfig}, NOT ${runnerConfig}: the
        # store file has no `server:` section and the daemon would refuse to
        # start with no connections declared.
        ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner --config ${composedConfig} daemon";
      };
    };
  };
}
