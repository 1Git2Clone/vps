# ==============================================================================
# Minecraft — Fabric server
# ==============================================================================
# The world is large and the weekly quiescent backup stops the server, so the
# stop path is the part that matters here. See modules/backups.nix.
#
# Individual mods are managed via MODRINTH_PROJECTS ( Modrinth project slugs ).
# The image auto-selects the newest compatible version for the MC version + loader.
# To switch to a modpack instead, use MODPACK_PLATFORM + MODRINTH_MODPACK or CF_SLUG.
{ config, lib, ... }:

{
  sops.templates."minecraft.env".content = ''
    RCON_PASSWORD=${config.sops.placeholder.minecraft_rcon_password}
  '';

  virtualisation.oci-containers.containers.minecraft = {
    image = "itzg/minecraft-server:java25";

    environment = {
      EULA = "TRUE";
      ENABLE_RCON = "true";

      TYPE = "FABRIC";
      VERSION = "26.1.2";

      MEMORY = "5G";

      ONLINE_MODE = "TRUE";
      ENABLE_WHITELIST = "TRUE";
      ENFORCE_WHITELIST = "TRUE";

      DIFFICULTY = "hard";
      GAMEMODE = "survival";
      MOTD = "A Place for Gemstones to Chill";

      # Individual mods via Modrinth (auto-selects newest for 26.1.2 Fabric).
      # Remove a slug to uninstall; add a slug to install.
      # :beta suffix needed for mods without a stable release for this MC version.
      MODRINTH_PROJECTS = lib.concatStringsSep "," [
        "cloth-config"
        "config-manager:beta"
        "dlaw-fabric"
        "fabric-api"
        "fabric-language-kotlin"
        "fabric-permissions-api"
        "fallingtree"
        "ferrite-core"
        "forge-config-api-port"
        "lithium"
        "no-chat-reports"
        "placeholder-api"
        "serversleep"
        "sound-physics-remastered:beta"
        "voxy-server-side"
        "yacl"
      ];
    };

    environmentFiles = [ config.sops.templates."minecraft.env".path ];

    ports = [
      "25565:25565"
      # RCON on loopback only. It is an unauthenticated-by-design remote console
      # once you have the password, so it never leaves the host.
      "127.0.0.1:25575:25575"
    ];

    volumes = [ "minecraft_data:/data" ];

    extraOptions = [
      "--security-opt=no-new-privileges:true"
      "--tmpfs=/tmp"
      # Docker's default stop grace is 10s. A large world does not finish saving
      # in 10s, and the weekly backup stops the server — a SIGKILL mid-save is
      # how worlds get corrupted. The server saves and exits well inside this.
      "--stop-timeout=300"
    ];
  };

  # The module's default is 120s, which would have systemd kill the unit while
  # docker is still politely waiting out the 300s above.
  systemd.services.docker-minecraft.serviceConfig.TimeoutStopSec = lib.mkForce 360;
}
