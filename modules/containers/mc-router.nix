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
# The cost: worlds see mc-router's address, not the player's. Nothing here
# keys on a player IP (whitelist and bans are by UUID); PROXY protocol would
# fix it but needs a mod on every world.
{ config, lib, ... }:

let
  inherit (config.infra) domain mcNetwork;
in
{
  virtualisation.oci-containers.containers.mc-router = {
    image = "itzg/mc-router:1.48.0@sha256:3a9ece070b97c8c55666810fc81cb209e1dd775fce792187e296626b786859cc";

    environment = {
      MAPPING = lib.concatStringsSep "," [
        "minecraft.${domain}=minecraft:25565"
        "mc.${domain}=minecraft:25565"
        "mc2.${domain}=minecraft2:25565"
      ];
      # Bare-IP joins land where they always did.
      DEFAULT = "minecraft:25565";

      AUTO_SCALE_WEBHOOK_URL = "http://${config.infra.mcGateway}:${toString config.infra.mcScalerPort}/scale";
      AUTO_SCALE_DOWN_AFTER = "10m";
      # A modded world takes well over the 60s default to boot.
      AUTO_SCALE_WEBHOOK_WAKE_TIMEOUT = "3m";
      AUTO_SCALE_ASLEEP_MOTD = "Asleep. Join to wake it up";
      AUTO_SCALE_LOADING_MOTD = "Waking up, join again in a minute";
    };

    ports = [ "25565:25565" ];
    networks = [ mcNetwork ];

    extraOptions = [
      "--ip=${config.infra.mcRouterAddress}"
      "--security-opt=no-new-privileges:true"
      "--read-only"
    ];
  };
}
