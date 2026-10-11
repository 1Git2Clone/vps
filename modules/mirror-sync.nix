# Keeps hutao/<repo> on Forgejo in step with an upstream GitHub repo: its
# `main` and its tags, every hour. The point is a copy that outlives the
# upstream — OpenRadioss's GitHub repo was deleted outright on 2026-10-01 and
# its fork had to be rebuilt from whoever still had a clone.
#
# ADDING A REPO IS ONE LINE in `mirrors` below. The Forgejo repo must exist
# first (create it empty, or push to it once by hand).
#
# WHAT IT REFUSES TO DO, ON PURPOSE: overwrite history. The push is never
# forced, so an upstream that rewrites or empties `main`, or moves a tag, fails
# that repo's push and leaves the mirror as it was. That is the case a mirror
# exists for, so it shows up as a failed unit (`systemctl status mirror-sync`)
# instead of being followed. To accept a rewrite you trust, force-push that one
# repo by hand.
#
# Only `main` and tags. Other branches stay whatever they are on Forgejo, which
# is what keeps each repo's own `pages` branch out of this; and some upstream
# branches start workflows on a push (cadcraft's `release` runs its release
# pipeline on the runner), which `main` here does not.
#
# Each push to Forgejo as hutao needs a token with write on `repository`,
# sops key mirror_sync/token (see secrets.example.yaml).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # One line per mirror: "<github owner>/<repo>", synced to hutao/<repo>.
  mirrors = [
    "storytold/photocraft"
    "storytold/cadcraft"
    "storytold/effectcraft"
    "storytold/filmcraft"
  ];
in
{
  systemd.services.mirror-sync = {
    description = "Sync upstream main and tags into the Forgejo mirrors";
    after = [
      "network-online.target"
      "docker-forgejo.service"
    ];
    wants = [ "network-online.target" ];

    environment = {
      MIRRORS = lib.concatStringsSep " " mirrors;
      SRC_BASE = "https://github.com";
      DST_BASE = "https://git.${config.infra.domain}/hutao";
      GIT_TERMINAL_PROMPT = "0";
    };

    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      # A bare copy per repo, so each run fetches only what is new instead of
      # cloning everything again.
      StateDirectory = "mirror-sync";
      LoadCredential = [ "token:${config.sops.secrets.mirror_sync_token.path}" ];

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      SystemCallFilter = [ "@system-service" ];
      CapabilityBoundingSet = [ ];
    };

    path = with pkgs; [
      git
      coreutils
    ];

    script = ''
      set -uo pipefail

      # Basic auth with the token as the password. In the environment, not on
      # the command line, so it never shows up in the process list.
      auth=$(printf 'hutao:%s' "$(cat "$CREDENTIALS_DIRECTORY/token")" | base64 -w0)
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0="http.$DST_BASE/.extraheader"
      export GIT_CONFIG_VALUE_0="Authorization: Basic $auth"

      failed=0
      for m in $MIRRORS; do
        repo=''${m##*/}
        dir="$STATE_DIRECTORY/$repo.git"
        [ -d "$dir" ] || git init -q --bare "$dir"
        # The local copy follows upstream exactly, rewrites included; the push
        # below is where a rewrite gets refused.
        if git -C "$dir" fetch -q --no-tags "$SRC_BASE/$m.git" '+refs/heads/main:refs/heads/main' '+refs/tags/*:refs/tags/*' \
          && git -C "$dir" push -q "$DST_BASE/$repo.git" refs/heads/main:refs/heads/main 'refs/tags/*:refs/tags/*'; then
          echo "mirror-sync: $m -> hutao/$repo ok"
        else
          echo "mirror-sync: $m -> hutao/$repo FAILED, left as it was" >&2
          failed=1
        fi
      done
      exit "$failed"
    '';
  };

  systemd.timers.mirror-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "10m";
      Persistent = true;
    };
  };
}
