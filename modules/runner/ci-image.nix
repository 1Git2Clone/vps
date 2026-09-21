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

      # /usr/bin/env, which this image otherwise does not have. dockerTools
      # links `contents` into /bin and creates no /usr at all, while nixos/nix
      # ships the usual /usr/bin/env — so a workflow that worked on the `nix`
      # label dies here on anything with the most common shebang in the
      # ecosystem:
      #
      #   #!/usr/bin/env node
      #
      # Every binary npm and pnpm install starts that way, so `pnpm check` on
      # skavex failed at its first step with a message that names the
      # interpreter rather than the script, which reads like a broken install:
      #
      #   sh: node_modules/@typescript/native/bin/tsc:
      #   /usr/bin/env: bad interpreter: No such file or directory
      #   [runner]: exitcode '126': failure
      #
      # This is the one FHS path worth providing. It is not a step toward
      # making the image look like a distro: /usr/bin/env is load-bearing for
      # portable shebangs specifically, which is why it survives in images that
      # otherwise have no /usr.
      mkdir -p usr/bin
      ln -s ${pkgs.coreutils-full}/bin/env usr/bin/env
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
    # pull of a localhost/ reference no registry can serve.
    #
    # NO RemainAfterExit, and its absence is the fix for a real outage rather
    # than a style choice. With it set, systemd considered this unit active
    # forever after its first success, so it never ran again — and because the
    # unit's own definition does not change when anything else in this file
    # does, a deploy could not restart it either. When the daily prune deleted
    # the image, `deploy` installed the prune hook that would prevent the NEXT
    # deletion and left the CURRENT one in place: every job on the label kept
    # failing in three seconds until the unit was restarted by hand.
    #
    # Without it the unit goes inactive on success, which is what makes both
    # healing paths work: activation starts wanted-but-inactive units, so a
    # deploy reloads the image, and so does every restart of the runner. The
    # flag only ever bought skipping a `podman load` whose layers are already
    # on disk — a second or two, traded for a failure mode that needed an ssh
    # session to clear.
    systemd.services.forgejo-runner-ci-image = {
      description = "Load the nix+node job image into podman";
      wantedBy = [ "multi-user.target" ];
      before = [ "forgejo-runner.service" ];
      requiredBy = [ "forgejo-runner.service" ];
      after = [ "podman.service" ];
      wants = [ "podman.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      # `podman load` is idempotent for an identical archive and cheap when the
      # layers are already present, so this can run unguarded.
      script = ''
        ${config.virtualisation.podman.package}/bin/podman load \
          --input ${config.runner.ciImage}
      '';
    };

    # THE GARBAGE COLLECTOR EATS THIS IMAGE, and the unit above cannot notice.
    #
    # autoPrune runs `podman system prune -f --all` daily. `--all` removes every
    # image no container references, and between jobs nothing references this
    # one — so it is deleted like any other cold image. The load unit is a
    # oneshot with RemainAfterExit, which means that after its first success at
    # activation systemd considers it active forever and will not run it again.
    # Nothing puts the image back until the next reboot.
    #
    # The failure is not subtle once seen but is invisible in review: with
    # force_pull false the runner tries to use a localhost/ reference that no
    # registry can serve, and every job on the nix-node label dies in about
    # three seconds, on workflows that were green hours earlier and did not
    # change. Observed 2026-09-21 across cv-template, skavex and nixos-dotfiles
    # at once.
    #
    # ExecStartPost rather than OnSuccess=: OnSuccess only STARTS a unit, and
    # starting a RemainAfterExit oneshot that systemd already believes is active
    # does nothing at all — which is the same trap again one layer up. `restart`
    # runs it regardless of what state systemd thinks it is in. --no-block so
    # prune does not wait on a unit that is ordered after it.
    # mkIf, because this attribute is the only thing this module says about
    # podman-prune. With autoPrune disabled that unit is not defined by anything
    # else, and setting serviceConfig on it would conjure a unit with an
    # ExecStartPost and no ExecStart — a broken service invented by a module
    # trying to protect against a collector that is not running.
    systemd.services.podman-prune.serviceConfig.ExecStartPost =
      lib.mkIf config.virtualisation.podman.autoPrune.enable
        [
          "${config.systemd.package}/bin/systemctl restart --no-block forgejo-runner-ci-image.service"
        ];
  };
}
