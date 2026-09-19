# ==============================================================================
# Renovate, on the host
# ==============================================================================
# This was .forgejo/workflows/renovate.yml and ran on the CI runner. It moved
# here when the runner moved off this box, for one reason: RENOVATE_TOKEN is a
# bot account with WRITE on repository and issue across hutao/* and skavex/*,
# and the workflow injected it into a job container once a day. A runner we
# explicitly do not trust does not get a long-lived cross-org write credential.
#
# Moving it also deletes the constraint the workflow's own header called out —
# "THE TOKEN IS NOT IN SOPS ... this runs in a job container, which cannot read
# the host's filesystem". On the host it is an ordinary sops secret like every
# other credential here.
#
# The cost, stated plainly: Renovate's node closure now builds and runs on the
# box that serves mail. It is a pinned flake input this repo already trusts
# enough to run, it runs once a day under a locked-down unit, and unlike the
# runner the closure PERSISTS between runs — so this is cheaper in bandwidth
# than the workflow was, and more expensive in disk.
#
# devShells.renovate in flake.nix has the same package list, for humans
# running Renovate by hand — kept, unchanged. This unit does NOT invoke it;
# see the `script` comment below for why.
{ config, pkgs, ... }:

{
  systemd.services.renovate = {
    description = "Open dependency update pull requests";

    # Renovate shells out to `nix flake update` for lockFileMaintenance, so the
    # daemon has to be up and git has to be on PATH.
    after = [
      "network-online.target"
      "nix-daemon.service"
    ];
    wants = [ "network-online.target" ];

    # Deliberately the same package list as devShells.renovate in flake.nix,
    # duplicated rather than reused — see the `script` comment below for why
    # this unit cannot just `nix develop` that shell.
    path = with pkgs; [
      # Pinned through the flake, so the thing proposing updates is itself a
      # line in flake.lock — lockFileMaintenance bumps Renovate exactly like
      # everything else.
      renovate

      # Renovate shells out to `nix flake update` for lockFileMaintenance.
      # RENOVATE_BINARY_SOURCE=global means it spawns whatever is on PATH, so
      # a missing `nix` here breaks lock maintenance alone while every other
      # repo's updates keep working.
      nix

      # Its git work happens through the git on PATH.
      git

      # For git operations over ssh (fetching/pushing to non-http remotes).
      openssh

      # pnpm_10, NOT unversioned pnpm: skavex's pnpm-lock.yaml is
      # lockfileVersion '9.0' and declares no `packageManager` field, so
      # nothing tells Renovate which major to use. nixpkgs' unversioned pnpm
      # is 11, and a major that rewrites the lockfile format would turn every
      # update into a whole-file diff. Pin it to the major that wrote the
      # lock. Without any pnpm at all, npm-manager repos die on
      # `spawn pnpm ENOENT` — but only AFTER the branch is already pushed, so
      # Renovate opens the PR anyway with the lockfile untouched and an
      # artifactErrors comment on it.
      pnpm_10
    ];

    serviceConfig = {
      Type = "oneshot";

      # Not DynamicUser: the run needs a writable checkout and a nix store
      # connection, and a stable StateDirectory is what keeps it from
      # re-downloading its closure every night.
      User = "renovate";
      Group = "renovate";
      StateDirectory = "renovate";
      WorkingDirectory = "/var/lib/renovate";

      LoadCredential = [
        "token:${config.sops.secrets.renovate_token.path}"
        "github:${config.sops.secrets.renovate_github_com_token.path}"
      ];

      # It runs upstream node code with a write token. Confine it to the
      # directory it needs and nothing else on a box that holds mail.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };

    environment = {
      RENOVATE_PLATFORM = "forgejo";
      RENOVATE_ENDPOINT = "https://git.${config.infra.domain}/api/v1/";

      # autodiscoverFilter, NOT autodiscoverNamespaces — the latter resolves
      # each name through GET /api/v1/orgs/<name>/repos, which only knows
      # organizations, and `hutao` is a user. That 404 killed the first run
      # before any repo was processed. Carried over verbatim from the workflow.
      RENOVATE_AUTODISCOVER = "true";
      RENOVATE_AUTODISCOVER_FILTER = "hutao/*,skavex/*";

      # "use what is on PATH" — otherwise Renovate installs a second Nix.
      RENOVATE_BINARY_SOURCE = "global";

      NIX_CONFIG = "experimental-features = nix-command flakes";

      # No RENOVATE_GIT_AUTHOR. Renovate reads the name and email of whatever
      # account the token belongs to and compares each commit's author against
      # it to decide "did a human edit my branch?" — an override that does not
      # match makes it read its own commits as someone else's and stop updating
      # the branch.
    };

    # The two secrets are read from the credentials directory systemd sets up
    # for LoadCredential above, never from the environment or the store.
    #
    # Deliberately NOT `nix develop ${./..}#renovate -c renovate`. That
    # interpolates this repo's path into the Nix store as a `-source`
    # derivation and pulls it into the system closure whole — .git history,
    # .terraform provider binaries, and secrets.yaml included. Measured on a
    # built vps-hetzner toplevel: a 549 MiB store path, most of it
    # tofu/.terraform, that would change on every commit and land a
    # SOPS-encrypted secrets file in a world-readable /nix/store on the box
    # that serves mail. The unit does not need a shell environment, only the
    # four binaries above on PATH — do not "simplify" this back to reusing
    # the devShell.
    script = ''
      export RENOVATE_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/token")
      # Raises the anonymous github.com read limit from 60/hour. Without it
      # actions/checkout, cachix/install-nix-action and hashicorp/terraform are
      # rate-limited into silence — they do not error, they stop producing
      # updates, which is the failure you never notice.
      export RENOVATE_GITHUB_COM_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/github")
      exec renovate
    '';
  };

  systemd.timers.renovate = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Noon UTC, matching the cron this replaces. Persistent so a reboot
      # during the window does not skip a day.
      OnCalendar = "12:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  users.users.renovate = {
    isSystemUser = true;
    group = "renovate";
    home = "/var/lib/renovate";
  };
  users.groups.renovate = { };
}
