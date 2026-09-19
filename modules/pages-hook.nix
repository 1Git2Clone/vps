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
# the box — in fact it never leaves the PROXY NETWORK, because this receiver is
# a container on it too. There is no caddy site, no published port, no DNS name
# and no firewall rule: `pages-hook:9000` is reachable from containers on that
# network and from nothing else at all.
#
# A CONTAINER, NOT A HOST SERVICE, AND THAT IS A SECURITY FIX RATHER THAN
# TIDYING. The first version of this module ran on the host and bound
# infra.dockerBridgeGateway, which meant Forgejo had to be allowed to reach that
# address — and ALLOWED_HOST_LIST matches HOSTS, NOT host:port. Allowing
# 172.17.0.1 therefore allowed a webhook aimed at anything bound there, and
# grafana (3000), syncthing's GUI (8384), tempo (4317/4318) and pgbouncer (6432)
# all bind 0.0.0.0 and answer on it. Forgejo webhooks can use GET and record the
# RESPONSE BODY in their delivery history, so that was a read primitive with an
# exfiltration channel attached: anyone who could create a webhook could read
# tailnet-only services without being on the tailnet.
#
# Moving here closes it. ALLOWED_HOST_LIST is now the container name, and
# Forgejo's matcher is `MatchHostName(host) || MatchIPAddr(ip)` (see
# modules/hostmatcher) — a name pattern alone is sufficient, so nothing needs to
# allow a private address and 172.17.0.1 stops matching entirely.
#
# ONE SYSTEM WEBHOOK, NOT ONE PER REPO. Forgejo's /admin/hooks fires for every
# repository on the instance, which is the only shape that preserves what
# pages-pull's discovery bought: adding a pages site is a workflow file in the
# repo that wants one, with nothing to configure here.
#
# THE RECEIVER PARSES NOTHING. Any successful Action Run pokes pages-pull, which
# is already idempotent (a stamp file per repo skips an unchanged artifact) and
# already cheap. Reading the payload would buy a slightly smaller number of
# no-op runs in exchange for coupling this module to Forgejo's ActionPayload
# schema.
#
# THE RECEIVER CANNOT START ANYTHING. Its entire capability is touching one file
# in a bind-mounted directory; a systemd .path unit on the host watches that
# file and starts pages-pull as root. A network-facing process that can run
# `systemctl start` is root-adjacent, and the indirection costs six lines.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) pagesHookPort proxyNetwork;

  uid = config.infra.serviceId.pages-hook;

  # The host side of the signal. /run, so it is tmpfs: a trigger file cannot
  # survive a reboot, and nothing here is data that should.
  #
  # A BIND MOUNT, against this repo's own "data is a named volume, never a bind
  # mount" rule, and the exception is deliberate. That rule exists so restic
  # picks up a new service's data automatically (see modules/backups.nix); this
  # is not data, it is one zero-byte file used as an IPC signal, and a named
  # volume would both be backed up for no reason and persist across reboots.
  triggerDir = "/run/pages-hook";
  triggerFile = "${triggerDir}/trigger";

  # Where the same directory appears inside the container.
  containerTriggerDir = "/trigger";

  # adnanh/webhook's hook definition. Two things about it are load-bearing:
  #
  # `getenv` rather than the secret itself, with `-template` below. This file is
  # a NIX STORE PATH and the store is world-readable, so a secret written here
  # would be readable by every user on the box. The value arrives at runtime
  # through an env file instead.
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
            name = "${containerTriggerDir}/trigger";
          }
        ];
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

  # Built locally rather than pulled, the same way caddy is: there is no
  # upstream image for "webhook plus the one coreutils binary it shells out to",
  # and building it means the contents are pinned by flake.lock like everything
  # else. `webhook` alone would not do — the hook's command is `touch`, which
  # has to exist inside the container.
  #
  # -ip 0.0.0.0 is correct HERE and would not have been on the host. Inside the
  # container the only interface is the proxy network, and the port is NOT
  # published, so "all interfaces" is one interface reachable by containers on
  # that network alone.
  hookImage = pkgs.dockerTools.buildLayeredImage {
    name = "pages-hook";
    tag = pkgs.webhook.version;
    contents = [ pkgs.coreutils ];
    config = {
      Entrypoint = [ "${pkgs.webhook}/bin/webhook" ];
      Cmd = [
        "-hooks"
        "${hooks}"
        "-template"
        "-ip"
        "0.0.0.0"
        "-port"
        (toString pagesHookPort)
        # -verbose, and it is not noise. Without it webhook logs its startup
        # line and then NOTHING per delivery, so a hook that silently stops
        # being delivered looks exactly like a week with no pushes. That is the
        # failure shape half the modules in this repo carry comments about, and
        # a few lines an hour is a cheap way not to have it.
        "-verbose"
        "-nopanic"
      ];
    };
  };
in
{
  # The secret reaches the container as an ENV FILE, not a mounted template.
  # Both forms exist in this repo and the difference matters: docker resolves a
  # mounted symlink once and pins the inode, so a rotated secret never arrives.
  # An env file is re-read by docker at container start, and `restartUnits`
  # makes sops-nix restart this one when — and only when — the rendered content
  # actually changes, so a no-op deploy does not bounce the listener.
  sops.templates."pages-hook.env" = {
    content = ''
      PAGES_HOOK_SECRET=${config.sops.placeholder.forgejo_system_webhooks_pages_pull_secret}
    '';
    restartUnits = [ "docker-pages-hook.service" ];
  };

  # The container writes here, so the host has to create it first and hand it to
  # the container's uid. 0700: nothing else on this box has any business reading
  # or writing a trigger that starts a root unit.
  systemd.tmpfiles.rules = [
    "d ${triggerDir} 0700 ${toString uid} ${toString uid} -"
  ];

  virtualisation.oci-containers.containers.pages-hook = {
    image = "pages-hook:${pkgs.webhook.version}";
    imageFile = hookImage;

    # NOT on `proxy` for proxying — nothing reverse-proxies this and caddy has
    # no site for it. It is there because FORGEJO is, and Forgejo is the one
    # thing that has to reach it. See FORGEJO__webhook__ALLOWED_HOST_LIST in
    # modules/containers/forgejo.nix, which names this container.
    networks = [ proxyNetwork ];

    # NO `ports`. Publishing one would put this back on the host, undo the
    # reason it is a container at all, and need a firewall rule again.

    environmentFiles = [ config.sops.templates."pages-hook.env".path ];

    volumes = [
      "${triggerDir}:${containerTriggerDir}"
    ];

    extraOptions = [
      "--user=${toString uid}:${toString uid}"
      "--read-only"
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges"
      # webhook writes nothing but the trigger and the rootfs is read-only, so
      # /tmp only has to exist.
      "--tmpfs=/tmp:rw,noexec,nosuid,size=1m"
    ];
  };

  # The privileged half, and the reason the half above needs none. `.path` is a
  # core systemd primitive: it watches the file and starts the unit. Nothing
  # grants the container the ability to start anything.
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
