# ==============================================================================
# mc-router — the one public door to every Minecraft world
# ==============================================================================
# It reads the hostname out of the client's handshake, so every world shares
# 25565 and none needs a port or an SRV record of its own. The worlds are in
# ./minecraft.nix, and the cap on how many run at once in ./minecraft-cap.nix.
#
# A login to a sleeping world POSTs {"action":"up"} to minecraft-scaler and
# holds the player until the world's port answers; 10 minutes after the last
# player leaves it POSTs {"action":"down"}. Only logins wake a world or reset
# that timer, not server-list pings (1.48.0+), so scanners cannot keep one
# awake.
#
# ONLY WHITELISTED PLAYERS WAKE A WORLD. A scanner that sends a login, not
# just a ping, otherwise boots a world for nothing; on 2026-10-22 one hit the
# default route minutes after the first deploy. The allowlist is built from
# the worlds' own whitelist.json at every start, so the in-game whitelist stays
# the one list, and no player name or UUID lands in this public repo.
#
# Two things to know:
#
#   * mc-router cannot authenticate a player: it compares the UUID the client
#     CLAIMS in its login packet. Mojang's check happens at the world, which is
#     online-mode with an enforced whitelist. So this stops strangers waking
#     worlds; it is not what keeps them out.
#   * mc-router reads the list only at start. After `/whitelist add`, restart
#     docker-mc-router (which drops everyone connected) before that player
#     can WAKE a world. Joining one that is already up works straight away.
#
# The cost: worlds see mc-router's address, not the player's. Nothing here
# keys on a player IP (whitelist and bans are by UUID); PROXY protocol would
# fix it but needs a mod on every world.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain mcNetwork;

  allowDeny = "/run/mc-router/allow-deny.json";
  whitelists = map (
    w: "/var/lib/docker/volumes/${w}_data/_data/whitelist.json"
  ) config.minecraftCap.worlds;

  # An EMPTY allowlist lets everyone through in mc-router (it falls back to the
  # denylist), so the list always carries one entry that matches nobody. No
  # readable whitelist, or a malformed one, then means nobody wakes a world
  # rather than anybody.
  nobody = "00000000-0000-0000-0000-000000000001";
  buildAllowDeny = pkgs.writeShellScript "mc-router-allow-deny" ''
    mkdir -p /run/mc-router
    files=()
    for f in ${lib.escapeShellArgs whitelists}; do
      [ -r "$f" ] && files+=("$f")
    done
    # /dev/null first: with no files, jq -s would read stdin.
    if ! ${pkgs.jq}/bin/jq -s '{global: {allowlist: ([.[][] | {uuid}] | unique) + [{uuid: "${nobody}"}]}}' \
      /dev/null "''${files[@]}" > ${allowDeny}.tmp; then
      echo "mc-router-allow-deny: a whitelist did not parse, nobody can wake a world" >&2
      echo '{"global": {"allowlist": [{"uuid": "${nobody}"}]}}' > ${allowDeny}.tmp
    fi
    chmod 0644 ${allowDeny}.tmp
    mv ${allowDeny}.tmp ${allowDeny}
    echo "mc-router-allow-deny: $(${pkgs.jq}/bin/jq '.global.allowlist | length - 1' ${allowDeny}) players may wake a world"
  '';
in
{
  virtualisation.oci-containers.containers.mc-router = {
    image = "itzg/mc-router:1.48.0@sha256:3a9ece070b97c8c55666810fc81cb209e1dd775fce792187e296626b786859cc";

    environment = {
      MAPPING = lib.concatStringsSep "," [
        "minecraft.${domain}=minecraft:25565"
        "mc.${domain}=minecraft:25565"
        "mc2.${domain}=minecraft2:25565"
        "mc3.${domain}=minecraft3:25565"
      ];
      # Bare-IP joins land where they always did.
      DEFAULT = "minecraft:25565";

      AUTO_SCALE_WEBHOOK_URL = "http://${config.infra.mcGateway}:${toString config.infra.mcScalerPort}/scale";
      AUTO_SCALE_DOWN_AFTER = "10m";
      # A modded world takes well over the 60s default to boot.
      AUTO_SCALE_WEBHOOK_WAKE_TIMEOUT = "3m";
      AUTO_SCALE_ASLEEP_MOTD = "Asleep. Join to wake it up";
      AUTO_SCALE_LOADING_MOTD = "Waking up, join again in a minute";
      AUTO_SCALE_ALLOW_DENY = "/config/allow-deny.json";
    };

    volumes = [ "${allowDeny}:/config/allow-deny.json:ro" ];

    ports = [ "25565:25565" ];
    networks = [ mcNetwork ];

    extraOptions = [
      "--ip=${config.infra.mcRouterAddress}"
      "--security-opt=no-new-privileges:true"
      "--read-only"
    ];
  };

  systemd.services.docker-mc-router.serviceConfig.ExecStartPre = lib.mkBefore [ "${buildAllowDeny}" ];
}
