# Explicit registration for programs using a few GiB. No measured threshold.
# Minecraft's backup hold remains specific to Minecraft; every registered unit
# shares the same admission limit, including manual systemctl starts.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.highMemory;
  systemctl = "${config.systemd.package}/bin/systemctl";
  guard =
    name: program:
    pkgs.writeShellScript "high-memory-${name}" ''
      exec 9>/run/high-memory.lock
      ${pkgs.util-linux}/bin/flock 9
      # Several units can already be "activating" while waiting for this lock.
      # Reserve admission explicitly, so pending guards do not count each other
      # and all refuse. A passed guard keeps its full weight through ExecStart/Stop.
      mkdir -p /run/high-memory-admitted
      rm -f ${lib.escapeShellArg "/run/high-memory-admitted/${name}.service"}
      ${lib.optionalString (program.holdFile != null) ''
        if [ -e ${lib.escapeShellArg program.holdFile} ]; then
          echo "high-memory: ${name} is held for backup" >&2
          exit 1
        fi
      ''}
      used=0
      ${lib.concatStrings (
        lib.mapAttrsToList (
          other: registered:
          let
            unit = lib.escapeShellArg "${other}.service";
            slots = toString registered.slots;
          in
          ''
            u=${unit}
            case "$(${systemctl} show -P ActiveState "$u")" in
              inactive | failed) rm -f "/run/high-memory-admitted/$u" ;;
              activating)
                if [ -e "/run/high-memory-admitted/$u" ]; then used=$((used + ${slots})); fi
                ;;
              *) used=$((used + ${slots})) ;;
            esac
          ''
        ) (lib.removeAttrs cfg.programs [ name ])
      )}
      if [ "$((used + ${toString program.slots}))" -gt ${toString cfg.maxRunning} ]; then
        echo "high-memory: $used slots used (cap ${toString cfg.maxRunning}); ${name} needs ${toString program.slots}, refusing" >&2
        exit 1
      fi
      touch ${lib.escapeShellArg "/run/high-memory-admitted/${name}.service"}
    '';
in
{
  options.highMemory = {
    maxRunning = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Maximum occupied high memory usage slots.";
    };
    programs = lib.mkOption {
      default = { };
      description = "Explicit high memory usage program registry, keyed by systemd unit name without .service.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            slots = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Number of admission slots occupied while this program is starting, running or stopping.";
            };
            holdFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional backup hold that prevents this program from starting.";
            };
          };
        }
      );
    };
  };
  config.systemd.services = lib.mapAttrs (name: program: {
    # `+`: admission takes the shared root-owned lock even for a unit that
    # runs as another user.
    serviceConfig.ExecCondition = "+${guard name program}";
  }) cfg.programs;
}
