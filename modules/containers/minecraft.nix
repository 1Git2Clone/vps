# ==============================================================================
# Minecraft — Fabric servers
# ==============================================================================
# Two worlds, two containers. A world is a /data directory plus the server
# properties around it, so a second world is a second container on its own
# volume — never a second mount into the same one.
#
# The world is large and the weekly quiescent backup stops the server, so the
# stop path is the part that matters here. See modules/backups.nix, which stops
# BOTH containers for the one weekly snapshot.
#
# No world publishes its game port. mc-router owns the public 25565 and picks
# the world by the hostname the player typed, waking it through
# minecraft-scaler and putting it back to sleep when everyone has left. At most
# two are up at once — see ./minecraft-cap.nix. The MC versions differ on
# purpose — world 2's mods are built for 1.21.1 — which is why the mod lists
# are separate:
#
#   world       MC        hostnames               RCON (loopback)   volume
#   minecraft   26.1.2    minecraft. mc. bare IP   25575             minecraft_data
#   minecraft2  1.21.1    mc2.                     25576             minecraft2_data
#   minecraft3  26.2      mc3.                     25577             minecraft3_data
#
# World 3 is not a mod list here: it is a modpack, packs/mc3, which is also
# what its players install. See its container below.
#
# A new world is a container, an entry in `worlds` and a MAPPING line in
# ./mc-router.nix. The weekly backup, the cap and the scaler all follow
# `worlds`.
#
# Worlds 1 and 2 manage individual mods via MODRINTH_PROJECTS (Modrinth project
# slugs); the image auto-selects the newest compatible version for the MC
# version + loader. World 3 is a modpack instead (MODRINTH_MODPACK).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) mcNetwork;

  worlds = [
    "minecraft"
    "minecraft2"
    "minecraft3"
  ];

  # THE TWO LISTS ARE NOT SHARED, and cannot be: the worlds run different MC
  # versions (26.1.2 and 1.21.1), and a slug is only installable where that mod
  # has a build for that version + loader. Three of world 1's mods have no
  # 1.21.1 fabric build at all. Each list is verified against its OWN version.
  minecraftMods = [
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

  # World 2: the zombie set, on MC 1.21.1 — which is the version those mods are
  # built for. Below the zombie block is world 1's list minus what has no 1.21.1
  # fabric build, because a slug with no compatible build fails the WHOLE server
  # start in itzg's image. An unchecked slug here is an outage, not a missing mod.
  #
  # Every entry verified against the Modrinth API for fabric + 1.21.1 on
  # 2026-09-14. Recheck when this version moves; the answers are version-specific.
  #
  # The zombie mods are client_side=required — players need them installed
  # locally to join world 2, which is not true of world 1's set.
  #
  # ASKED FOR AND NOT INSTALLABLE:
  #   the-lost-cities  no fabric build for 1.21.1 (forge 1.20.1, neoforge
  #                    26.1.2, fabric 26.2-beta — nothing in between). It is
  #                    also a WORLDGEN mod, so it cannot be added after this
  #                    world generates: getting it means running world 2 on
  #                    26.2 from the start, and 26.2 loses vics-point-blank,
  #                    zombie-awareness, underground-bunkers and the horde mod.
  #
  # DROPPED FROM WORLD 1'S SET, no 1.21.1 fabric build:
  #   dlaw-fabric      oldest published build is 1.21.11
  minecraft2Mods = [
    "mebahels-zombie-horde"
    "mutants-and-zombies"
    "underground-bunkers"
    "vics-point-blank"
    "zombie-awareness"

    # LIBRARY DEPENDENCIES OF THE ABOVE, and the reason the first start of this
    # world failed with "Incompatible mods found!". MODRINTH_PROJECTS downloads
    # exactly the slugs it is given and nothing else, so a mod's own
    # requirements have to be listed here too:
    #
    #   geckolib   vics-point-blank hard-depends on it in fabric.mod.json and
    #              declares NOTHING on Modrinth — the API cannot tell you this,
    #              only the jar can. MODRINTH_DOWNLOAD_DEPENDENCIES=required
    #              would not have caught it either.
    #   coroutil   zombie-awareness depends on it (this one IS declared).
    #
    # Checked by reading fabric.mod.json out of every resolved jar, nested jars
    # included: with these two present, no hard `depends` in the whole set is
    # unmet. Do the same before adding a mod here.
    "coroutil"
    "geckolib"

    "cloth-config"
    "config-manager:beta"
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
    # :alpha, not :beta — at 1.21.1 this mod has published no RELEASE, so a bare
    # slug fails the start. :beta would install, but stops at fabric-1.21.1-1.4.10
    # (March 2025); :alpha is what reaches the newest build for this version.
    "sound-physics-remastered:alpha"
    "voxy-server-side"
    "yacl"
  ];

  # Docker's default stop grace is 10s. A large world does not finish saving in
  # 10s, and the weekly backup stops the server — a SIGKILL mid-save is how
  # worlds get corrupted. The server saves and exits well inside this.
  stopOptions = [
    "--security-opt=no-new-privileges:true"
    "--tmpfs=/tmp"
    "--stop-timeout=300"
  ];
in
{
  imports = [ ./minecraft-cap.nix ];

  minecraftCap.worlds = worlds;

  # One console password per world: <world>_rcon_password in modules/secrets.nix.
  sops.templates = lib.listToAttrs (
    map (
      w:
      lib.nameValuePair "${w}.env" {
        content = ''
          RCON_PASSWORD=${config.sops.placeholder."${w}_rcon_password"}
        '';
      }
    ) worlds
  );

  virtualisation.oci-containers.containers = {
    minecraft = {
      # Digest-pinned: java25 is a ROLLING tag, so the tag alone says nothing
      # about what runs. The digest is the image the world is currently on, read
      # off the box — a rebuild or a re-pull can no longer swap the JRE under a
      # live world without the swap appearing here as a diff.
      image = "itzg/minecraft-server:java25@sha256:d209013e65134d9c6aa0c962e81ddf1214efa733a4eec81d5d079b1b49c0a598";

      environment = {
        EULA = "TRUE";
        ENABLE_RCON = "true";

        TYPE = "FABRIC";
        VERSION = "26.1.2";

        # -Xms/-Xmx, split. itzg's MEMORY sets BOTH to the same value, so the JVM
        # commits the whole heap at boot and never gives it back — which is why an
        # idle server sat at 4+ G of RSS. A low floor plus G1's periodic
        # concurrent GC (JEP 346) lets it uncommit while nobody is on.
        INIT_MEMORY = "1G";
        MAX_MEMORY = "6G";

        # G1 only uncommits at the end of a GC cycle, and an idle server triggers
        # no GCs at all — so without a periodic one the heap stays at its
        # high-water mark forever. Costs one concurrent cycle per 5 min idle.
        JVM_XX_OPTS = "-XX:G1PeriodicGCInterval=300000";

        ONLINE_MODE = "TRUE";
        ENABLE_WHITELIST = "TRUE";
        ENFORCE_WHITELIST = "TRUE";

        DIFFICULTY = "hard";
        GAMEMODE = "survival";
        MOTD = "A Place for Gemstones to Chill";

        SPAWN_PROTECTION = "0";

        # Individual mods via Modrinth (auto-selects newest for 26.1.2 Fabric).
        # Remove a slug to uninstall; add a slug to install.
        # :beta suffix needed for mods without a stable release for this MC version.
        MODRINTH_PROJECTS = lib.concatStringsSep "," minecraftMods;
      };

      environmentFiles = [ config.sops.templates."minecraft.env".path ];

      # Woken by minecraft-scaler, not by boot: an idle world costs nothing.
      autoStart = false;
      networks = [ mcNetwork ];

      ports = [
        # RCON on loopback only. It is an unauthenticated-by-design remote console
        # once you have the password, so it never leaves the host.
        "127.0.0.1:25575:25575"
      ];

      volumes = [ "minecraft_data:/data" ];

      extraOptions = stopOptions;
    };

    # Second world. Same image, its own volume, its own RCON password — the two
    # consoles are deliberately not interchangeable.
    #
    # MAX_MEMORY is 4G rather than 6G: the box is a cx43 (16 G) and also runs
    # mail, forgejo, grafana and tempo. 6G + 6G leaves no headroom.
    #
    # VERSION IS 1.21.1, NOT world 1's 26.1.2. The zombie mods this world exists
    # for are built for 1.21.1 and stop there, so the version is the whole point
    # rather than an oversight — do not "sync" it with world 1. Moving it means
    # rechecking every slug in minecraft2Mods against the new version.
    minecraft2 = {
      # java21, not java25 like world 1: 1.21.1 targets Java 21, and its mods are
      # compiled against it. Mixin/ASM on a JDK newer than the one a mod was built
      # for is the classic modded-server crash, and there is nothing to gain here.
      # Digest-pinned for the same reason as world 1, and it matters more here:
      # a rolling tag could move this world onto a newer JDK point release, which
      # is exactly the mixin/ASM break the paragraph above warns about.
      image = "itzg/minecraft-server:java21@sha256:50bdc4b0746c48456d8e737a017786a94c02295b14a8f0f4cb02592a0388cc09";

      environment = {
        EULA = "TRUE";
        ENABLE_RCON = "true";

        TYPE = "FABRIC";
        VERSION = "1.21.1";

        # -Xms/-Xmx, split. itzg's MEMORY sets BOTH to the same value, so the JVM
        # commits the whole heap at boot and never gives it back — which is why an
        # idle server sat at 4+ G of RSS. A low floor plus G1's periodic
        # concurrent GC (JEP 346) lets it uncommit while nobody is on.
        INIT_MEMORY = "1G";
        MAX_MEMORY = "4G";

        # G1 only uncommits at the end of a GC cycle, and an idle server triggers
        # no GCs at all — so without a periodic one the heap stays at its
        # high-water mark forever. Costs one concurrent cycle per 5 min idle.
        JVM_XX_OPTS = "-XX:G1PeriodicGCInterval=300000";

        ONLINE_MODE = "TRUE";
        ENABLE_WHITELIST = "TRUE";
        ENFORCE_WHITELIST = "TRUE";

        DIFFICULTY = "hard";
        GAMEMODE = "survival";
        MOTD = "A Second Place for Gemstones to Chill";

        # Vanilla defaults this to 16, which stops NON-OPS breaking any block
        # within 16 of world spawn — ops are exempt, so the symptom is "you have
        # to be op to build", not an error message. A whitelisted server has no
        # griefers to protect spawn from.
        SPAWN_PROTECTION = "0";

        # Auto-selects newest compatible for 1.21.1 Fabric — a DIFFERENT set of
        # builds from world 1's, which is why this list is its own.
        MODRINTH_PROJECTS = lib.concatStringsSep "," minecraft2Mods;
      };

      environmentFiles = [ config.sops.templates."minecraft2.env".path ];

      autoStart = false;
      networks = [ mcNetwork ];

      ports = [ "127.0.0.1:25576:25575" ];

      volumes = [ "minecraft2_data:/data" ];

      extraOptions = stopOptions;
    };

    # Third world: the Vanilla+ modpack on MC 26.2. Unlike worlds 1 and 2 it has
    # no MODRINTH_PROJECTS list: what it runs is packs/mc3, pinned to exact
    # versions, and the .mrpack built from it is mounted in for itzg to install.
    # itzg skips every file the pack marks client-only, and re-syncs the mods to
    # the pack on every start, so a pack change lands on the next wake. The SAME
    # file is the players' download (.forgejo/workflows/pages.yml), which is the
    # point: a mod both sides need cannot be at one version here and another in
    # the players' pack.
    #
    # MAX_MEMORY is 4G, as for world 2: with the cap at 2, the worst pair is still
    # world 1's 6G plus 4G.
    minecraft3 = {
      # java25, the same digest as world 1: 26.x targets Java 25.
      image = "itzg/minecraft-server:java25@sha256:d209013e65134d9c6aa0c962e81ddf1214efa733a4eec81d5d079b1b49c0a598";

      environment = {
        EULA = "TRUE";
        ENABLE_RCON = "true";

        # The pack names its own MC and fabric-loader versions, so there is no
        # VERSION here to disagree with them.
        TYPE = "MODRINTH";
        MODRINTH_MODPACK = "/modpack/vanilla-plus.mrpack";

        # See world 1 for why these are split.
        INIT_MEMORY = "1G";
        MAX_MEMORY = "4G";
        JVM_XX_OPTS = "-XX:G1PeriodicGCInterval=300000";

        ONLINE_MODE = "TRUE";
        ENABLE_WHITELIST = "TRUE";
        ENFORCE_WHITELIST = "TRUE";

        DIFFICULTY = "hard";
        GAMEMODE = "survival";
        MOTD = "A Third Place for Gemstones to Chill";

        # See world 2: 16 makes spawn op-only to build in.
        SPAWN_PROTECTION = "0";
      };

      environmentFiles = [ config.sops.templates."minecraft3.env".path ];

      autoStart = false;
      networks = [ mcNetwork ];

      ports = [ "127.0.0.1:25577:25575" ];

      volumes = [
        "minecraft3_data:/data"
        # itzg only takes a local pack whose name ends in .mrpack.
        "${pkgs.callPackage ../../packs/mc3.nix { }}:/modpack/vanilla-plus.mrpack:ro"
      ];

      extraOptions = stopOptions;
    };
  };

  # The module's default is 120s, which would have systemd kill the unit while
  # docker is still politely waiting out the 300s above.
  systemd.services = lib.genAttrs (map (w: "docker-${w}") worlds) (_: {
    serviceConfig.TimeoutStopSec = lib.mkForce 360;
  });
}
