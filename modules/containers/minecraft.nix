# ==============================================================================
# Minecraft — Fabric servers
# ==============================================================================
# Three worlds, three containers. A world is a /data directory plus the server
# properties around it, so another world is another container on its own
# volume — never a second mount into the same one.
#
# The worlds are large and the weekly quiescent backup stops the servers, so
# the stop path is the part that matters here. See modules/backups.nix, which
# stops every world for the one weekly snapshot.
#
# No world publishes its game port. mc-router owns the public 25565 and picks
# the world by the hostname the player typed, waking it through
# minecraft-scaler and putting it back to sleep when everyone has left. At most
# two are up at once — see ./minecraft-cap.nix. The MC versions differ on
# purpose — world 2's mods are built for 1.21.1:
#
#   world       pack   MC        hostnames                RCON (loopback)   volume
#   minecraft   mc1    26.1.2    minecraft. mc. bare IP   25575             minecraft_data
#   minecraft2  mc2    1.21.1    mc2.                     25576             minecraft2_data
#   minecraft3  mc3    26.2      mc3.                     25577             minecraft3_data
#   minecraft4  mc4    26.3      mc4.                     25578             minecraft4_data
#
# WHAT A WORLD RUNS IS ITS PACK, packs/<pack>, not a list here. Each is pinned
# to exact Modrinth versions, and the .mrpack built from it is mounted into the
# container for itzg to install (TYPE=MODRINTH). itzg skips every file the pack
# marks client-only and re-syncs the mods to the pack on every start, so a pack
# change lands on the next wake. The SAME file is the players' download
# (.forgejo/workflows/pages.yml): a mod both sides need cannot be at one
# version here and another in the players' pack. See packs/mrpack.nix.
#
# Worlds 1 and 2 were converted from MODRINTH_PROJECTS slug lists on
# 2026-10-25, pinned to the exact jars they were running (looked up on
# Modrinth by sha1), so the conversion installed nothing new on either.
#
# A new world is a pack, a container, an entry in `worlds` and a MAPPING line
# in ./mc-router.nix. The weekly backup, the cap and the scaler all follow
# `worlds`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) mcNetwork;

  packs = import ../../packs { inherit (pkgs) callPackage; };

  worlds = [
    "minecraft"
    "minecraft2"
    "minecraft3"
    "minecraft4"
  ];

  # Docker's default stop grace is 10s. A large world does not finish saving in
  # 10s, and the weekly backup stops the server — a SIGKILL mid-save is how
  # worlds get corrupted. The server saves and exits well inside this.
  stopOptions = [
    "--security-opt=no-new-privileges:true"
    # exec: mods unpack their native libraries into /tmp and load them from
    # there (netty's epoll and tcnative, krypton's compression, voxy's zstd).
    # Docker's tmpfs default is noexec, and with it every one of those fell
    # back to slower Java, which the start log says outright ("check volume
    # for noexec flag"). noexec was no boundary anyway: /data is an ordinary
    # exec mount, and mod code can write and load a library there just the
    # same. nosuid and nodev are what matter for escalation, and stay.
    #
    # size: the default is half the host's RAM, and a tmpfs's pages are RAM.
    # A mod filling /tmp could take ~7.6G on a box with no swap that also
    # runs mail. The natives are a few MB each.
    "--tmpfs=/tmp:rw,exec,nosuid,nodev,size=512m"
    "--stop-timeout=300"
  ];

  # One world's container. The pack names its own MC and fabric-loader
  # versions, so there is no VERSION here to disagree with it.
  world =
    {
      name,
      image,
      pack,
      rconPort,
      maxMemory,
      motd,
      # The world folder in /data. Unset is itzg's "world". A new name starts a
      # fresh world and leaves the old folder on the volume, untouched: the
      # reset is undone by putting the old name back.
      level ? null,
    }:
    {
      inherit image;

      environment = {
        EULA = "TRUE";
        ENABLE_RCON = "true";

        TYPE = "MODRINTH";
        MODRINTH_MODPACK = "/modpack/${pack.name}";

        # -Xms/-Xmx, split. itzg's MEMORY sets BOTH to the same value, so the
        # JVM commits the whole heap at boot and never gives it back — which is
        # why an idle server sat at 4+ G of RSS. A low floor plus G1's periodic
        # concurrent GC (JEP 346) lets it uncommit while nobody is on.
        INIT_MEMORY = "1G";
        MAX_MEMORY = maxMemory;

        # G1 only uncommits at the end of a GC cycle, and an idle server
        # triggers no GCs at all — so without a periodic one the heap stays at
        # its high-water mark forever. Costs one concurrent cycle per 5 min idle.
        JVM_XX_OPTS = "-XX:G1PeriodicGCInterval=300000";

        ONLINE_MODE = "TRUE";
        ENABLE_WHITELIST = "TRUE";
        ENFORCE_WHITELIST = "TRUE";

        DIFFICULTY = "hard";
        GAMEMODE = "survival";
        MOTD = motd;

        # Vanilla defaults this to 16, which stops NON-OPS breaking any block
        # within 16 of world spawn — ops are exempt, so the symptom is "you
        # have to be op to build", not an error message. A whitelisted server
        # has no griefers to protect spawn from.
        SPAWN_PROTECTION = "0";
      }
      // lib.optionalAttrs (level != null) { LEVEL = level; };

      environmentFiles = [ config.sops.templates."${name}.env".path ];

      # Woken by minecraft-scaler, not by boot: an idle world costs nothing.
      autoStart = false;
      networks = [ mcNetwork ];

      # RCON on loopback only. It is an unauthenticated-by-design remote
      # console once you have the password, so it never leaves the host.
      ports = [ "127.0.0.1:${toString rconPort}:25575" ];

      volumes = [
        "${name}_data:/data"
        # itzg only takes a local pack whose name ends in .mrpack, which the
        # pack's store name does.
        "${pack}:/modpack/${pack.name}:ro"
      ];

      extraOptions = stopOptions;
    };
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
    minecraft = world {
      name = "minecraft";
      # Digest-pinned: java25 is a ROLLING tag, so the tag alone says nothing
      # about what runs. The digest is the image the world is currently on,
      # read off the box — a rebuild or a re-pull can no longer swap the JRE
      # under a live world without the swap appearing here as a diff.
      image = "itzg/minecraft-server:java25@sha256:d209013e65134d9c6aa0c962e81ddf1214efa733a4eec81d5d079b1b49c0a598";
      pack = packs.mc1;
      rconPort = 25575;
      maxMemory = "6G";
      motd = "A Place for Gemstones to Chill";
    };

    # Second world: the zombie set. Its own volume and its own RCON password —
    # the consoles are deliberately not interchangeable.
    #
    # MAX_MEMORY is 4G rather than 6G: the box is a cx43 (16 G) and also runs
    # mail, forgejo, grafana and tempo. 6G + 6G leaves no headroom.
    #
    # ITS PACK IS ON 1.21.1, NOT world 1's 26.1.2. The zombie mods this world
    # exists for are built for 1.21.1 and stop there, so the version is the
    # whole point rather than an oversight — do not "sync" it with world 1.
    #
    # ASKED FOR AND NOT INSTALLABLE: the-lost-cities has no fabric build for
    # 1.21.1, and it is a WORLDGEN mod, so it cannot be added after this world
    # generates. Getting it means a new world on 26.2, which loses
    # vics-point-blank, zombie-awareness, underground-bunkers and the horde mod.
    minecraft2 = world {
      name = "minecraft2";
      # java21, not java25 like world 1: 1.21.1 targets Java 21, and its mods
      # are compiled against it. Mixin/ASM on a JDK newer than the one a mod
      # was built for is the classic modded-server crash. Digest-pinned for
      # the same reason as world 1, and it matters more here: a rolling tag
      # could move this world onto a newer JDK point release.
      image = "itzg/minecraft-server:java21@sha256:50bdc4b0746c48456d8e737a017786a94c02295b14a8f0f4cb02592a0388cc09";
      pack = packs.mc2;
      rconPort = 25576;
      maxMemory = "4G";
      motd = "A Second Place for Gemstones to Chill";
    };

    # Third world: the Vanilla+ modpack. 4G, as for world 2: with the cap at 2,
    # the worst pair is still world 1's 6G plus 4G.
    minecraft3 = world {
      name = "minecraft3";
      # java25, the same digest as world 1: 26.x targets Java 25.
      image = "itzg/minecraft-server:java25@sha256:d209013e65134d9c6aa0c962e81ddf1214efa733a4eec81d5d079b1b49c0a598";
      pack = packs.mc3;
      rconPort = 25577;
      maxMemory = "4G";
      motd = "A Third Place for Gemstones to Chill";
      # Reset on 2026-10-29, when Wilder Wild, Naturalist and Streams
      # Reflowing left the pack: their blocks were all through the old terrain.
      # The first world is still in this volume as `world`.
      level = "world-2026-10-29";
    };

    # Fourth world: mc1's pack, lightened for players on integrated graphics,
    # and on 26.3, which every mod it kept supports. Same image as world 1;
    # what it leaves out, and why, is in docs/src/minecraft/worlds/mc4.md.
    minecraft4 = world {
      name = "minecraft4";
      image = "itzg/minecraft-server:java25@sha256:d209013e65134d9c6aa0c962e81ddf1214efa733a4eec81d5d079b1b49c0a598";
      pack = packs.mc4;
      rconPort = 25578;
      maxMemory = "4G";
      motd = "A Fourth Place for Gemstones to Chill";
    };
  };

  # The module's default is 120s, which would have systemd kill the unit while
  # docker is still politely waiting out the 300s above.
  systemd.services = lib.genAttrs (map (w: "docker-${w}") worlds) (_: {
    serviceConfig.TimeoutStopSec = lib.mkForce 360;
  });
}
