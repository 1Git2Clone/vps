# ==============================================================================
# Forgejo Actions runner
# ==============================================================================
# `FORGEJO__actions__ENABLED` has been true since the port, so the instance has
# always accepted workflow files and then had nothing to run them. This is the
# missing half.
#
# The runner is DECLARED, not registered. Forgejo's Actions page creates the
# runner record and hands out its uuid and secret; both go into
# `server.connections` here, so the runner's identity is a config file rather
# than a `.runner` state file produced by a one-time `register` call against a
# short-lived registration token. Nothing about it is imperative, and there is
# no first-boot ordering to get right.
#
# The runner does NOT execute a job itself: it asks the host's docker daemon to
# create a container per job, which is why /var/run/docker.sock is mounted. That
# socket is root on this host, so a workflow that can choose its own image can
# also mount anything and become root. What keeps that acceptable here:
#
#   * registration is disabled on the instance (see forgejo.nix), so every repo
#     that could carry a workflow is one this box's owner put there;
#   * `container.valid_volumes` is an ALLOW-LIST of exactly one volume, so a
#     workflow cannot mount /var/lib/docker/volumes or the host root and read
#     another service's data;
#   * `container.docker_host` is "-", so the socket is not passed on into the
#     job containers;
#   * `container.privileged` is false, so a job container cannot reach the
#     host's devices or kernel interfaces.
#
# The remaining hole is the socket itself. Closing it properly means a
# docker-in-docker sidecar, which would also make the pages volume invisible to
# caddy — the publish step writes into a HOST volume, and a dind daemon has its
# own storage. That trade is why the socket is here rather than a dind
# container: the pages workflow only works this way round.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain pagesVolume dockerBridgeGateway;

  fqdn = "git.${domain}";

  # The port job containers reach the Actions cache proxy on. Fixed rather than
  # random (the runner's default) because it is published below, and a `ports`
  # entry cannot name a port the runner picks at startup.
  cacheProxyPort = 34567;

  # The public URL, not `http://forgejo:4242` over the proxy network. Two
  # reasons: the runner hands this URL to every job container, and a job is on
  # its own per-job network (see `container.network` below) where a
  # proxy-network container name does not resolve; and putting jobs on the proxy
  # network would let a workflow reach kuma, navidrome and searxng directly,
  # behind the caddy that is supposed to be their door.
  instanceUrl = "https://${fqdn}/";

  # 13.1.0, released 2026-08-31. The tag carries no `v`, unlike the git tag —
  # code.forgejo.org/forgejo/runner:v13.1.0 is a 404, which fails at pull time
  # rather than at build time.
  #
  # Bump with: curl -sS 'https://code.forgejo.org/api/v1/repos/forgejo/runner/releases?limit=5'
  image = "code.forgejo.org/forgejo/runner:13.1.0";

  # The runner record, from Site Administration -> Actions -> Runners -> Create
  # new runner. The uuid is an identifier, printed under the runner's name in
  # that list and not a credential; the secret it is paired with is, and lives
  # in sops. Delete the runner there and this line changes with it.
  connectionName = "hu-tao";
  runnerUuid = "496902b3-ff10-435f-b34b-b37d91b67c33";

  dataVolume = "forgejo_runner_data";

  # The secret, copied to a path that does not move. A sops secret's `path` is a
  # symlink into a generation directory, and docker resolves a symlink at mount
  # time and then holds that inode forever — so a rotated token would never
  # reach the container. Same reason dozzle-users.service exists.
  tokenFile = "/var/lib/forgejo-runner/token";
  tokenMount = "/run/forgejo-runner/token";

  # `label:docker://image` — the left half is what a workflow puts in
  # `runs-on:`, the right half is the image the job runs in. ubuntu-latest is a
  # lie everyone tells: it is what workflows written for GitHub say, and it must
  # carry node, because every JavaScript action (actions/checkout among them) is
  # executed by the node binary inside the JOB container.
  labels = [
    # What .forgejo/workflows/ci.yml runs on, and the reason it is not
    # ubuntu-latest: cachix/install-nix-action calls `sudo` unconditionally on
    # its non-systemd branch, node:22-bookworm has no sudo, and so every CI run
    # exited 127 before the first check. Shipping Nix in the image removes the
    # action entirely — and with it a Nix download on every run, on the box that
    # is also serving mail and git.
    #
    # It carries nix, bash, gitMinimal, curl and coreutils and NOTHING else. No
    # node, so a workflow on this label cannot use a JavaScript action —
    # actions/checkout included; ci.yml does its own `git fetch`. Its
    # /etc/nix/nix.conf already sets `sandbox = false`, which is what makes a
    # build work under `privileged: false` below.
    #
    # Bump with: curl -sS 'https://hub.docker.com/v2/repositories/nixos/nix/tags?page_size=5&ordering=last_updated'
    "nix:docker://nixos/nix:2.35.2"
    "ubuntu-latest:docker://node:22-bookworm"
    "node-22:docker://node:22-bookworm"
    "alpine:docker://alpine:3.22"
  ];

  # Assembled line by line rather than as one indented string: a multi-line
  # interpolation only indents its first line, and YAML is whitespace.
  runnerConfig = pkgs.writeText "forgejo-runner-config.yaml" (
    lib.concatStringsSep "\n" (
      [
        "# Generated by Nix — edit modules/containers/forgejo-runner.nix"
        "log:"
        "  level: info"
        ""
        "server:"
        "  connections:"
        "    ${connectionName}:"
        "      url: ${instanceUrl}"
        "      uuid: ${runnerUuid}"
        # token_url, not token: this file is a world-readable store path, so
        # the secret must never become a Nix string. `file:` is the one scheme
        # the runner resolves, and it trims the value, so a trailing newline in
        # the sops secret is harmless.
        "      token_url: file://${tokenMount}"
        "      labels:"
      ]
      ++ map (l: "        - ${l}") labels
      ++ [
        ""
        "runner:"
        # No `file:` key. That is the legacy `.runner` registration state, and
        # the loader REFUSES to start when it finds one next to a declared
        # connection — "server connection conflict ... only one config file can
        # provide server connections". Its default is $PWD/.runner, i.e.
        # /data/.runner, so a volume carrying one from an older setup has to be
        # emptied rather than ignored.
        #
        # Two jobs at once on a box that also serves mail, git and a minecraft
        # server. Raise it only after watching a real build's load.
        "  capacity: 2"
        "  timeout: 30m"
        ""
        "cache:"
        # Something needs it now. serenity-discord-bot runs six compile jobs per
        # push and each one rebuilt the whole dependency graph from scratch:
        # measured locally, a clean `cargo build --all-features` is 375s against
        # 15s with a warm target directory. `Swatinem/rust-cache@v2` had been in
        # that workflow the whole time doing nothing, because a runner with the
        # cache disabled sets no ACTIONS_CACHE_URL and the action then no-ops
        # without logging a word.
        "  enabled: true"
        # Inside the runner's existing data volume, so the cache survives a
        # container replacement and restic already backs it up with everything
        # else under /var/lib/docker/volumes.
        "  dir: /data/cache"
        # Two ports, and only this one matters from outside. `port` is the
        # internal cache SERVER, which only the proxy in the same container
        # talks to — left random on purpose. `proxy_port` is what job containers
        # connect to via ACTIONS_CACHE_URL, so it has to be fixed for the
        # `ports` entry below to name it.
        "  proxy_port: ${toString cacheProxyPort}"
        # The address written into ACTIONS_CACHE_URL. It has to be reachable
        # FROM a job container, and a job container is on a per-job network (see
        # container.network) that docker isolates from this runner's bridge — so
        # container-to-container is out, and it must be an address on the HOST.
        "  host: \"${dockerBridgeGateway}\""
        ""
        "container:"
        # Empty, NOT "bridge". This is the one setting that decides whether a
        # workflow's `services:` work at all.
        #
        # "bridge" is docker's DEFAULT bridge, and the default bridge is the one
        # network with no embedded DNS — containers on it are reachable by IP and
        # by nothing else. A job that does
        #
        #     services:
        #       postgres: { image: postgres:18.2 }
        #     env:
        #       DATABASE_URL: postgres://…@postgres:5432/…
        #
        # then fails with "failed to lookup address information: Name or service
        # not known", after its wait loop has burned the full timeout. That is
        # what every run of serenity-discord-bot's test job did.
        #
        # Empty is the runner's own default: a network created per job, torn down
        # with it, on which the runner registers each service under its workflow
        # name. DNS works, so `postgres` and `redis` resolve.
        #
        # Per-job, not one shared network, matters at capacity 2 — two concurrent
        # jobs both aliasing `postgres` on a shared network would round-robin
        # between each other's databases.
        "  network: \"\""
        "  privileged: false"
        # The allow-list, and the whole reason a workflow can publish a page.
        # Any other `volumes:` entry in a workflow is refused by the runner.
        "  valid_volumes:"
        "    - ${pagesVolume}"
        # "-" means "mount NO docker host in the job container". This key is not
        # the runner's own connection to the daemon — that is the socket mounted
        # below — it is what gets handed to every JOB. Naming the socket here
        # would put the host's docker inside each workflow container, which is
        # precisely the access the allow-list above exists to deny.
        "  docker_host: \"-\""
      ]
    )
    + "\n"
  );
in
{
  systemd.services.forgejo-runner-token = {
    description = "Install the Forgejo runner token at a stable path";
    requiredBy = [ "docker-forgejo-runner.service" ];
    before = [ "docker-forgejo-runner.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Readable by the image's uid, and by nothing else on the host.
    script = ''
      install -D -m 0400 -o 1000 -g 1000 \
        ${config.sops.secrets.forgejo_runner_token.path} ${tokenFile}
    '';
  };

  virtualisation.oci-containers.containers.forgejo-runner = {
    inherit image;

    # Absolute path, and --config before the subcommand. The image's entrypoint
    # is dumb-init, so this list is its argv: a bare "forgejo-runner" would be a
    # PATH lookup done by dumb-init rather than by a shell.
    cmd = [
      "/bin/forgejo-runner"
      "--config"
      "/config.yaml"
      "daemon"
    ];

    volumes = [
      "${runnerConfig}:/config.yaml:ro"
      "${tokenFile}:${tokenMount}:ro"
      "${dataVolume}:/data"
      "/var/run/docker.sock:/var/run/docker.sock"
    ];

    # No `networks`: the runner has no reason to sit on any of the named ones,
    # and it talks to the instance over the public address like any other
    # client. It therefore lands on docker's default bridge, whose gateway is
    # the address `ports` publishes on below.

    # The Actions cache proxy, and the ONLY port this container publishes.
    #
    # Bound to docker0's gateway rather than 0.0.0.0, as a second lock on a door
    # modules/firewall.nix already closes. 0.0.0.0 would NOT expose this: a
    # published port is DNAT'd and then forwarded, that forward chain is
    # policy-drop, and 34567 is not in its public allow-list — traffic from the
    # internet arrives with `iifname eth0` and is dropped and logged. The bind
    # address is still worth setting because it does not depend on that
    # allow-list staying correct, and the chain is edited whenever a service is
    # published.
    #
    # The direction that must work is already covered: the same chain accepts
    # `iifname "br-*"`, which is every per-job network a job can land on.
    ports = [ "${dockerBridgeGateway}:${toString cacheProxyPort}:${toString cacheProxyPort}" ];

    extraOptions = [
      # The image runs as uid 1000, and /var/run/docker.sock is root:docker
      # 0660 — so membership in the host's docker group is what lets the runner
      # create job containers at all. Read from the config rather than written
      # as 131: NixOS assigns the gid statically, but a literal here would go
      # stale silently and the failure is "permission denied while trying to
      # connect to the Docker daemon socket" on every job.
      "--group-add=${toString config.users.groups.docker.gid}"
    ];
  };
}
