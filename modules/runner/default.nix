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
{
  config,
  lib,
  pkgs,
  ...
}:

let
  instanceUrl = "https://git.${config.infra.domain}/";

  # infra.cacheProxyPort (modules/options.nix), not a local literal: this file
  # and modules/runner/firewall.nix both have to agree on the number, and a
  # shared option is what makes that agreement structural instead of a
  # comment two files hope stays in sync.
  cacheProxyPort = config.infra.cacheProxyPort;

  # Written by modules/runner/identity.nix. Named here rather than there
  # because this is the consumer and the option that points at it is here.
  tokenEnvFile = "/var/lib/forgejo-runner-token/token.env";
in
# The imports list grows by one line in each of the next two tasks —
# ./identity.nix in Task 3, ./firewall.nix in Task 4. Adding them here would
# make this task's build fail on a missing file.
{
  imports = [
    ./networking.nix
    ./users.nix
    ./identity.nix
    ./firewall.nix
  ];

  virtualisation.podman = {
    enable = true;

    # /run/docker.sock as a Symlink on podman.socket, whose SocketGroup is
    # `podman`. Upstream's gitea-actions-runner module adds the runner to that
    # group itself (SupplementaryGroups, when podman is enabled), so nothing
    # here has to name a gid — which is the gid-goes-stale-silently failure the
    # VPS runner's --group-add comment warns about, avoided by construction.
    dockerSocket.enable = true;

    # The `docker` alias binary, so a workflow step that runs `docker build`
    # works unmodified. This was the requirement.
    dockerCompat = true;

    # 80 GB, and job images are the fastest-growing thing on it. Daily and
    # --all, because an image no job references is by definition not a warm
    # cache — the store and the Actions cache are what make a clone cheap, and
    # those are handled separately below.
    autoPrune = {
      enable = true;
      dates = "daily";
      flags = [ "--all" ];
    };

    # LOAD-BEARING, and the podman spelling of the lesson already written into
    # the VPS runner's `container.network: ""` comment. A network without
    # embedded DNS makes a workflow's `services:` unresolvable:
    #
    #   services:
    #     postgres: { image: postgres:18.2 }
    #   env:
    #     DATABASE_URL: postgres://…@postgres:5432/…
    #
    # fails with "failed to lookup address information", and the failure is not
    # an error but a wait loop burning the job's full timeout.
    defaultNetwork.settings.dns_enabled = true;
  };

  # Harder than modules/nix.nix's weekly/30d, which is tuned for a box whose
  # store barely moves. This one builds every push: four job images, a nix
  # store that grows with every flake input, and an Actions cache.
  # mkForce because nix.nix sets both and the merge would otherwise be an error
  # on `dates` and a silent keep on `options`.
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

  services.gitea-actions-runner = {
    # forgejo-runner, NOT the default gitea-actions-runner. nixpkgs has both;
    # the default is Gitea's 1.0.3 and this is Forgejo's 13.1.0 — the exact
    # version the VPS runs as code.forgejo.org/forgejo/runner:13.1.0, so
    # behaviour is unchanged across the move.
    package = pkgs.forgejo-runner;

    instances.forgejo = {
      enable = true;

      # The display name in Site Administration -> Actions -> Runners. Every
      # clone from the snapshot carries the same one; Forgejo tells them apart
      # by the uuid it issues at registration, so duplicates are cosmetic.
      name = config.networking.hostName;

      # The PUBLIC url, and it has to be. The runner hands this to every job
      # container, and a job container sits on a per-job network (see
      # container.network below) where no internal name resolves. It is also
      # the one destination modules/runner/firewall.nix permits.
      url = instanceUrl;

      # REGISTERED, not declared. The VPS runner's identity is a uuid+secret
      # pair in config, which is right for one permanent runner and impossible
      # for N clones — a uuid identifies exactly one runner record, and two
      # daemons claiming one record is undefined. A registration token can be
      # reused, so each clone self-registers and gets its own record.
      #
      # This option is mapped onto systemd's EnvironmentFile=, NOT read as a
      # token: upstream's ExecStartPre reads $TOKEN. The file therefore holds
      # the line `TOKEN=<token>`. See modules/runner/identity.nix.
      tokenFile = tokenEnvFile;

      # Unchanged from the VPS runner, so no workflow in any repo needs an
      # edit. `ubuntu-latest` is a lie everyone tells: it is what workflows
      # written for GitHub say, and it must carry node, because every
      # JavaScript action (actions/checkout among them) is executed by the node
      # binary inside the JOB container.
      #
      # nixos/nix carries nix, bash, gitMinimal, curl and coreutils and NOTHING
      # else — no node, so a workflow on that label cannot use a JavaScript
      # action; .forgejo/workflows/ci.yml does its own `git fetch`.
      labels = [
        "nix:docker://nixos/nix:2.35.2"
        "ubuntu-latest:docker://node:22-bookworm"
        "node-22:docker://node:22-bookworm"
        "alpine:docker://alpine:3.22"
      ];

      settings = {
        log.level = "info";

        runner = {
          # 4 vCPU at cx33, and nothing else on the box competing for them —
          # unlike the VPS, where this same 2 shared a machine with mail, git
          # and two JVMs.
          capacity = 2;
          timeout = "30m";
        };

        cache = {
          # Something needs it: serenity-discord-bot runs six compile jobs per
          # push, and a clean `cargo build --all-features` is 375s against 15s
          # with a warm target directory. Swatinem/rust-cache@v2 silently
          # no-ops when the runner sets no ACTIONS_CACHE_URL.
          enabled = true;

          # Under the instance's StateDirectory, which upstream sets to
          # /var/lib/gitea-runner and DynamicUser owns.
          dir = "/var/lib/gitea-runner/forgejo/cache";

          # Two ports, and only this one is reachable from outside the daemon.
          # `port` is the internal cache SERVER, left random on purpose;
          # proxy_port is what job containers connect to via ACTIONS_CACHE_URL,
          # so it has to be fixed for firewall.nix to name it.
          proxy_port = cacheProxyPort;

          # `host` is deliberately UNSET. Upstream detects the outbound address
          # automatically, which on this box is the public IPv4 — and that is
          # the one address a job container can reach the host at whichever
          # per-job network it landed on. Naming podman's default bridge
          # (10.88.0.1) instead would depend on a bridge that netavark creates
          # lazily and that a per-job network does not use.
          #
          # This is the single most likely thing in this file to be wrong. It
          # is verified by an actual cache hit in Phase 5, not by reading.
        };

        container = {
          # Empty, NOT "bridge". A per-job network, created and torn down with
          # the job, on which the runner registers each service under its
          # workflow name — which is what makes `services:` resolve. Per-job
          # rather than shared also matters at capacity 2: two concurrent jobs
          # both aliasing `postgres` on one network would round-robin between
          # each other's databases.
          network = "";

          privileged = false;

          # EMPTY, where the VPS runner allowed exactly one entry. That entry
          # was the pages volume, and the pages volume does not exist on this
          # box — caddy serves it from the VPS. See the pages pull in Phase 7.
          valid_volumes = [ ];

          # CHANGED from the VPS runner's "-", which meant "mount no docker
          # host in the job container". Here jobs get podman's socket, which is
          # the requirement: a CI run that uses docker should work.
          #
          # Note this is NOT the runner's own connection to the engine —
          # upstream sets DOCKER_HOST for the service itself when podman is
          # enabled. This key is what gets handed to every JOB.
          docker_host = "unix:///run/podman/podman.sock";
        };
      };
    };
  };
}
