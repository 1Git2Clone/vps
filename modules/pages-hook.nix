# ==============================================================================
# The pages webhook — turning a poll into an event
# ==============================================================================
# modules/pages-pull.nix used to be a five-minute timer and nothing else, and
# the comment there said a webhook "would make it instant again at the price of
# an HTTP receiver on the mail server, which is not a trade worth making for a
# static site". That was wrong, and wrong in a specific way worth recording:
# it assumed the receiver had to be PUBLIC.
#
# Forgejo is a container on this same host. Its webhook delivery never leaves
# the box — it goes container → docker bridge → here. There is no caddy site,
# no published port, no DNS name and no new internet surface. The thing that
# looked expensive costs one input rule of exactly the shape the bot and caddy
# already have.
#
# ONE SYSTEM WEBHOOK, NOT ONE PER REPO. Forgejo's /admin/hooks fires for every
# repository on the instance, which is the only shape that preserves what
# pages-pull's discovery bought: adding a pages site is a workflow file in the
# repo that wants one, with nothing to configure here. A per-repo hook would
# put the per-repo step straight back.
#
# THE RECEIVER PARSES NOTHING. Any successful Action Run pokes pages-pull, which
# is already idempotent (a stamp file per repo skips an unchanged artifact) and
# already cheap (a handful of HTTP calls to a container on this host). Reading
# the payload would buy a slightly smaller number of no-op runs in exchange for
# coupling this module to Forgejo's ActionPayload schema, which is not a trade
# worth making either — and this time that is measured rather than assumed.
#
# THE LISTENER HAS NO PRIVILEGE. It runs as a DynamicUser and its entire
# capability is touching one file in its own RuntimeDirectory; a systemd .path
# unit watches that file and starts pages-pull as root. A network-facing
# process that can run `systemctl start` is a network-facing process that is
# root-adjacent, and the indirection costs six lines.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) pagesHookPort dockerBridgeGateway;

  # The trigger file, and the only thing the listener can write. Under /run so
  # it is tmpfs and cannot survive a reboot into a spurious trigger.
  runtimeDir = "pages-hook";
  triggerFile = "/run/${runtimeDir}/trigger";

  # adnanh/webhook's hook definition. Two things about it are load-bearing:
  #
  # `getenv` rather than the secret itself, with `-template` below. This file
  # is a NIX STORE PATH and the store is world-readable, so a secret written
  # here would be readable by every user on the box — the exact rule
  # modules/options.nix opens with. The value arrives at runtime through an
  # EnvironmentFile instead.
  #
  # BACKTICKS, NOT QUOTES, AROUND THE VARIABLE NAME, and this is not cosmetic.
  # `-template` expands the file as a Go template BEFORE parsing it as JSON, so
  # it sees the raw bytes — and builtins.toJSON escapes an inner `"` to `\"`,
  # which the template parser rejects outright:
  #
  #   couldn't load hooks from file! template: hooks:1: unexpected "\" in operand
  #
  # The hook then simply does not exist and every delivery 404s. Go templates
  # take backtick raw strings, which JSON passes through untouched. Found by
  # running it; nothing about the Nix or the JSON looks wrong.
  #
  # X-Hub-Signature-256 of the four signature headers Forgejo sends (also
  # X-Forgejo-Signature, X-Gitea-Signature and the sha1 X-Hub-Signature — see
  # 16.0.4's services/webhook/shared/payloader.go). It carries GitHub's
  # `sha256=` prefix and is the shape webhook's rule is documented against.
  # Measured: webhook accepts the bare-hex Gitea header too, so this is a
  # convention rather than a constraint.
  hooks = pkgs.writeText "pages-hook.json" (
    builtins.toJSON [
      {
        id = "pages-pull";
        execute-command = "${pkgs.coreutils}/bin/touch";
        pass-arguments-to-command = [
          {
            source = "string";
            name = triggerFile;
          }
        ];
        # No response body worth returning, and no reason to make the caller wait
        # for the touch.
        response-message = "queued";
        trigger-rule = {
          match = {
            type = "payload-hmac-sha256";
            secret = "{{ getenv `PAGES_HOOK_SECRET` }}";
            parameter = {
              source = "header";
              name = "X-Hub-Signature-256";
            };
          };
        };
      }
    ]
  );
in
{
  # The secret reaches the process as an ENV FILE, not a mounted template.
  # Both forms exist in this repo and the difference matters: docker resolves a
  # mounted symlink once and pins the inode, so a rotated secret never arrives.
  # systemd re-reads an EnvironmentFile on every start, and `restartUnits`
  # makes sops-nix restart this one when — and only when — the rendered content
  # actually changes, so a no-op deploy does not bounce the listener.
  sops.templates."pages-hook.env" = {
    content = ''
      PAGES_HOOK_SECRET=${config.sops.placeholder.pages_hook_secret}
    '';
    restartUnits = [ "pages-hook.service" ];
  };

  systemd.services.pages-hook = {
    description = "Receive Forgejo action-run webhooks and poke pages-pull";
    wantedBy = [ "multi-user.target" ];
    # docker0 has to exist before anything can bind its address.
    after = [
      "network-online.target"
      "docker.service"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      # -ip, so the socket exists on the bridge address ALONE. The firewall
      # rule in modules/firewall.nix is the control; this is the second one
      # that has to also fail before anything off this host could reach it,
      # and it is the cheaper of the two to get right.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.webhook}/bin/webhook"
        "-hooks ${hooks}"
        "-template"
        "-ip ${dockerBridgeGateway}"
        "-port ${toString pagesHookPort}"
        "-nopanic"
      ];
      EnvironmentFile = config.sops.templates."pages-hook.env".path;

      RuntimeDirectory = runtimeDir;
      RuntimeDirectoryMode = "0700";

      # A listener on a network socket gets the full set. DynamicUser is the
      # important one: there is no account to take over, and the process can
      # write exactly one directory.
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_UNIX"
      ];
      CapabilityBoundingSet = "";

      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # The privileged half, and the reason the half above needs none. `.path` is
  # a core systemd primitive: it watches the file and starts the unit. Nothing
  # grants the listener the ability to start anything.
  systemd.paths.pages-pull-trigger = {
    description = "Start pages-pull when the webhook receiver signals";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      # Modified, not Exists. PathExists re-fires for as long as the file is
      # there, which with a file that is never deleted is a hot loop;
      # PathModified fires on the touch and then waits for the next one.
      PathModified = triggerFile;
      Unit = "pages-pull.service";
    };
  };
}
