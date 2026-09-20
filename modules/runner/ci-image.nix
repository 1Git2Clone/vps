# ==============================================================================
# The job image that can run JavaScript actions
# ==============================================================================
# WHY THIS EXISTS. Every JavaScript action — actions/checkout included — is
# executed by a `node` binary inside the JOB container, not by the runner. The
# `nix` label is nixos/nix, which carries nix, bash, gitMinimal, curl and
# coreutils and no node, so on that label `uses:` cannot run at all and every
# workflow has to hand-write its checkout as a `git fetch`.
#
# That is not just inconvenient, it is a correctness trap. A hand-written fetch
# is anonymous unless the author remembers to thread the job token through it,
# and on a PUBLIC repo an anonymous fetch works — so the omission is invisible
# on five of the six repos on this instance and fatal on the sixth. cv-template,
# the one private repo, failed with:
#
#   fatal: could not read Username for 'https://git.hu-tao.dev':
#   terminal prompts disabled
#   [runner]: exitcode '128': failure
#
# actions/checkout defaults its `token` input to the injected job token, so on
# an image with node the private-repo case needs no thought from the workflow
# author. Giving the runner an image with node is therefore the fix for both
# complaints at once.
#
# WHY NOT $GITHUB_PATH. modules/../.forgejo/workflows/pages.yml already makes a
# JS action run on the nix label by putting the dev shell's node on $GITHUB_PATH
# before the `uses:` step. That works for an action LATER in the job and cannot
# work for checkout, because it runs `nix develop .#ci` — which needs the repo
# already checked out. Node has to exist before any repo content does, which
# means it has to be in the image.
#
# WHY NOT A RUNNER SETTING. There isn't one. forgejo-runner's `container:`
# section is network, enable_ipv6, privileged, options, workdir_parent,
# valid_volumes, docker_host, force_pull, force_rebuild. Nothing supplies a node
# to the job container; GitHub's hosted runners simply ship one in the image.
#
# WHY NO REGISTRY. force_pull defaults to false, so the runner uses a locally
# present image without reaching for a registry. That means this can be an
# ordinary Nix derivation loaded into podman at activation — pinned by
# flake.lock, rebuilt only when its inputs change, and with no push credential,
# no pull secret and no package visibility to get wrong.
#
# THIS IS A SECOND LABEL, NOT A REPLACEMENT. `nix` still points at nixos/nix and
# is untouched. vps, skavex, compress and serenity-discord-bot keep building on
# exactly the image they build on today; a repo opts in by changing `runs-on`.
# A broken image here cannot take CI down for four working repos.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  imageName = "localhost/forgejo-ci-nix-node";
  imageTag = "latest";

  # buildLayeredImageWithNixDb, not buildLayeredImage. The plain builder copies
  # the store paths in but leaves /nix/var/nix/db empty, and a nix that cannot
  # read its own database treats every path in the image as absent — `nix
  # develop` then rebuilds a closure that is already sitting on the disk. The
  # WithNixDb variant registers them, which is the difference between a warm
  # image and a very slow one.
  image = pkgs.dockerTools.buildLayeredImageWithNixDb {
    name = imageName;
    tag = imageTag;

    contents =
      (with pkgs; [
        nix
        nodejs_22

        # bashInteractive rather than bash: the runner runs each `run:` block
        # through a shell it execs in the container, and act's default shell
        # detection wants a real bash. coreutils-full for `env`, `base64` and
        # the rest an action's wrapper script reaches for.
        bashInteractive
        coreutils-full

        # git is the one every checkout needs; the rest are what JS actions and
        # `docker cp`-style file transfer assume are present. This list is the
        # nixos/nix contents plus node plus the archive tools, not an attempt at
        # a general-purpose distro.
        git
        gnutar
        gzip
        xz
        curl
        findutils
        gnugrep
        gnused
        which

        cacert
      ])
      ++ [
        # /etc/passwd, /etc/group and /etc/nsswitch.conf. Without them `whoami`,
        # `git` and anything calling getpwuid() fail in a way that reads as a
        # permissions problem rather than a missing file.
        pkgs.dockerTools.fakeNss
      ];

    config = {
      Cmd = [ "/bin/bash" ];
      WorkingDir = "/";
      Env = [
        "PATH=/bin:/usr/bin:/sbin:/usr/sbin"
        "HOME=/root"
        "USER=root"

        # All three spellings. nix, curl and git each read a different one, and
        # a missing CA shows up as an opaque TLS failure deep inside a fetch.
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };

    # nix.conf is baked in rather than left to each workflow's NIX_CONFIG:
    #
    #   * experimental-features — every workflow here sets this itself today,
    #     and an image where `nix develop` works out of the box is one less
    #     thing a new repo has to copy correctly.
    #   * build-users-group = (empty) — there is no nix daemon and no nixbld
    #     group in this image. Left unset, nix refuses to build as root.
    #   * sandbox = false — the sandbox needs user namespaces the job container
    #     does not have (container.privileged is false, deliberately, and
    #     should stay that way). This is the same trade nixos/nix's own image
    #     makes; the isolation boundary here is the disposable VM, not the
    #     builder.
    extraCommands = ''
      mkdir -p tmp etc/nix root
      chmod 1777 tmp
      cat > etc/nix/nix.conf <<'CONF'
      experimental-features = nix-command flakes
      build-users-group =
      sandbox = false
      CONF
    '';
  };
in
{
  options.runner = {
    ciImage = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = image;
      description = "Job image carrying both nix and node, loaded into podman at activation.";
    };

    # The single source of the image's name. identity.nix builds its label from
    # this rather than repeating the string, so the label and the thing it
    # names cannot drift apart — a rename is one edit, not two, and there is no
    # check to forget to run because there is nothing to keep in sync.
    ciImageRef = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = "${imageName}:${imageTag}";
      description = "Fully-qualified local reference the runner label resolves to.";
    };
  };

  config = {
    # Ordered BEFORE the runner rather than merely wanted by multi-user: a
    # runner that starts first will advertise the nix-node label and can be
    # handed a job for an image that is not loaded yet, and the job fails on a
    # pull of a localhost/ reference no registry can serve. RemainAfterExit so
    # a restart of the runner does not re-run a load that already happened.
    systemd.services.forgejo-runner-ci-image = {
      description = "Load the nix+node job image into podman";
      wantedBy = [ "multi-user.target" ];
      before = [ "forgejo-runner.service" ];
      requiredBy = [ "forgejo-runner.service" ];
      after = [ "podman.service" ];
      wants = [ "podman.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # `podman load` is idempotent for an identical archive and cheap when the
      # layers are already present, so this can run on every boot without
      # guarding on whether the tag exists. The guard that DOES matter is the
      # tag check: autoPrune runs daily with --all and will delete this image if
      # no container references it, so re-loading unconditionally is what makes
      # the image survive its own garbage collector.
      script = ''
        ${config.virtualisation.podman.package}/bin/podman load \
          --input ${config.runner.ciImage}
      '';
    };
  };
}
