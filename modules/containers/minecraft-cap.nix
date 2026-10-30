# ==============================================================================
# Minecraft — at most `maxRunning` worlds at once, started on demand
# ==============================================================================
# The box is a cx43 (16 G, no swap) that also carries mail, so every world
# running at its heap ceiling at once is the OOM killer's call to make. Nothing
# off the shelf caps how many worlds run (panels cap memory per server, and
# mc-router only starts and stops them), so the cap lives here, in front of
# systemd, where it holds for every caller: mc-router's webhook, a hand-typed
# `systemctl start`, and the weekly backup's restart alike.
#
# Two pieces:
#
#   * an ExecCondition on each world's unit that counts the OTHER worlds that
#     are up and refuses at `maxRunning`. ExecCondition rather than
#     ExecStartPre: a refusal there skips the start instead of failing the
#     unit, so Restart=always (modules/containers/default.nix) has nothing to
#     retry. "Up" is any state but inactive/failed — a world that is still
#     saving on its way down holds its memory just the same.
#
#   * minecraft-scaler, the receiver for mc-router's scale webhook. `up` is a
#     `systemctl start` followed by a check that the unit actually came up, so
#     a start the cap refused answers 409 and mc-router drops that login
#     instead of waiting out its wake timeout on a world that is not coming.
#
# `holdFile` stops every start outright; modules/backups.nix uses it.
#
# Exercised end to end by tests/minecraft-cap.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.minecraftCap;
  systemctl = "${config.systemd.package}/bin/systemctl";
  unit = world: "docker-${world}.service";

  guard =
    world:
    pkgs.writeShellScript "minecraft-cap-${world}" ''
      # Serialised, so two worlds starting together cannot both count one other
      # world and both pass. Whoever goes second sees the first as activating.
      exec 9>/run/minecraft-cap.lock
      ${pkgs.util-linux}/bin/flock 9

      if [ -e ${cfg.holdFile} ]; then
        echo "minecraft-cap: ${cfg.holdFile} exists, not starting ${world}" >&2
        exit 1
      fi

      up=0
      for u in ${lib.escapeShellArgs (map unit (lib.remove world cfg.worlds))}; do
        case "$(${systemctl} show -P ActiveState "$u")" in
          inactive | failed) ;;
          *) up=$((up + 1)) ;;
        esac
      done

      if [ "$up" -ge ${toString cfg.maxRunning} ]; then
        echo "minecraft-cap: $up other worlds are up (cap ${toString cfg.maxRunning}), not starting ${world}" >&2
        exit 1
      fi
    '';

  # E501 only: the interpolated store paths are what run long.
  scaler = pkgs.writers.writePython3 "minecraft-scaler" { flakeIgnore = [ "E501" ]; } ''
    import json
    import subprocess
    from argparse import ArgumentParser
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    parser = ArgumentParser(description="Start capped worlds or acknowledge always-on routes")
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("worlds", nargs="+")
    parser.add_argument("--always-on", nargs="*", default=[])
    args = parser.parse_args()


    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096:
                    raise ValueError(length)
                req = json.loads(self.rfile.read(length))
                action = req["action"]
                # mc-router sends the backend from its own MAPPING, so this is
                # one of our container names, never anything a player typed.
                world = req["backend"].rsplit(":", 1)[0]
            except (ValueError, KeyError, TypeError, AttributeError):
                return self.reply(400)
            if action not in ("up", "down"):
                return self.reply(400)
            if world in args.always_on:
                # mc-router sends webhooks for every static route, even one
                # already running. These routes are managed independently:
                # never stop them on idle or bypass a backup's hold to start.
                return self.reply(200)
            if world not in args.worlds:
                return self.reply(400)

            unit = f"docker-{world}.service"
            if action == "down":
                # A world saves for up to 300s on the way down; mc-router's
                # request times out long before that.
                subprocess.run(["${systemctl}", "stop", "--no-block", unit])
                return self.reply(202)

            subprocess.run(["${systemctl}", "start", unit])
            up = subprocess.run(["${systemctl}", "is-active", "--quiet", unit])
            self.reply(200 if up.returncode == 0 else 409)

        def reply(self, code):
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()


    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
  '';
in
{
  options.minecraftCap = {
    worlds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Container names of the worlds the cap covers. Each is the unit docker-<name>.service.";
    };

    maxRunning = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "How many worlds may be up at once.";
    };

    alwaysOnWorlds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Always-on backend names whose scaler callbacks are acknowledged without starting or stopping them. Excluded from the cap.";
    };

    holdFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/minecraft-hold";
      readOnly = true;
      description = ''
        While this file exists no world starts, whoever asks. The weekly
        backup holds the worlds down with it, so a login cannot wake one
        while restic is reading its files.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.intersectLists cfg.worlds cfg.alwaysOnWorlds == [ ];
        message = "An always-on Minecraft route cannot also be a capped world.";
      }
    ];
    systemd.services =
      lib.listToAttrs (
        map (w: lib.nameValuePair "docker-${w}" { serviceConfig.ExecCondition = "${guard w}"; }) cfg.worlds
      )
      // {
        minecraft-scaler = {
          description = "Start and stop Minecraft worlds for mc-router";
          wantedBy = [ "multi-user.target" ];
          # It binds the gateway address, which exists once the network does.
          after = [ "docker-network-${config.infra.mcNetwork}.service" ];
          requires = [ "docker-network-${config.infra.mcNetwork}.service" ];

          serviceConfig = {
            ExecStart =
              "${scaler} ${config.infra.mcGateway} ${toString config.infra.mcScalerPort} ${lib.escapeShellArgs cfg.worlds}"
              + lib.optionalString (
                cfg.alwaysOnWorlds != [ ]
              ) " --always-on ${lib.escapeShellArgs cfg.alwaysOnWorlds}";
            Restart = "always";
            RestartSec = 5;

            # Root because systemd only takes start/stop from root or polkit,
            # and polkit is off on this box. Root with no capabilities at all:
            # the one thing it can still do is talk to systemd, and the code
            # only ever names the units in `worlds`.
            CapabilityBoundingSet = "";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
            ];
            # The firewall already admits only mc-router; this holds even if
            # that rule is ever broadened.
            IPAddressDeny = "any";
            IPAddressAllow = config.infra.mcRouterAddress;
          };
        };
      };
  };
}
