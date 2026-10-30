# Standalone, always-on vanilla Horizon trial. Fabric worlds and their cap stay
# separate. Only mc-router reaches the game; no admin panel is published.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  package = pkgs.callPackage ../../packages/horizon-server.nix { };
  id = toString config.infra.serviceId.horizon;
  volume = "/var/lib/docker/volumes/horizon_data/_data";
  settings = (pkgs.formats.toml { }).generate "horizon-server.toml" {
    server = {
      motd = "Horizon 26.3 - hu-tao.dev";
      port = 25565;
      bind = "0.0.0.0";
      max_players = 10;
      online_mode = true;
      whitelist = true;
      enforce_whitelist = true;
      view_distance = 10;
      simulation_distance = 6;
    };
    world = {
      name = "world";
      seed = "";
      game_mode = "survival";
      difficulty = "normal";
      hardcore = false;
    };
    engine = {
      path = "${package}/bin/horizon-engine";
      resources = "/resources";
      restart_on_crash = false;
    };
    backups = {
      every = "6h";
      keep = 12;
    };
    panel = {
      bind = "127.0.0.1:8130";
      allow_public = false;
    };
  };
  image = pkgs.dockerTools.buildLayeredImage {
    name = "horizon-server";
    tag = package.version;
    contents = [ pkgs.cacert ];
    config = {
      User = "${id}:${id}";
      WorkingDir = "/data";
      Cmd = [
        "${package}/bin/horizon-server"
        "run"
      ];
      Env = [
        "HOME=/data"
        "PATH=${package}/bin"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
  };
in
{
  minecraftCap.alwaysOnWorlds = [ "horizon" ];

  # Private game-derived resources are provisioned over SSH, outside the Nix
  # store and this public repo. A missing preparation fails before Docker runs.
  systemd.tmpfiles.rules = [
    "d /var/lib/horizon 0750 root horizon -"
    "d /var/lib/horizon/resources 0750 root horizon -"
    "d /var/lib/horizon/access 0750 root horizon -"
  ];

  virtualisation.oci-containers.containers.horizon = {
    image = "horizon-server:${package.version}";
    imageFile = image;
    networks = [ config.infra.mcNetwork ];
    volumes = [
      "horizon_data:/data"
      "/var/lib/horizon/resources:/resources:ro"
    ];
    extraOptions = [
      "--security-opt=no-new-privileges:true"
      "--cap-drop=ALL"
      "--read-only"
      "--tmpfs=/tmp:rw,nosuid,nodev,size=256m"
      "--memory=2g"
      "--stop-timeout=180"
    ];
  };

  systemd.services.docker-horizon = {
    serviceConfig = {
      ExecCondition = "${pkgs.coreutils}/bin/test ! -e ${config.minecraftCap.holdFile}";
      TimeoutStopSec = lib.mkForce 210;
    };
    preStart = lib.mkBefore ''
      test -s /var/lib/horizon/resources/registries.json
      test -s /var/lib/horizon/resources/commands.json
      # Horizon is owner-only. These private policy files are authoritative;
      # never inherit another world's players or operators, even on recovery.
      for file in whitelist.json ops.json; do
        ${pkgs.jq}/bin/jq -e '
          type == "array" and length == 1 and
          all(.[]; (.name | type == "string") and (.uuid | type == "string"))
        ' /var/lib/horizon/access/"$file" > /dev/null
      done
      ${pkgs.jq}/bin/jq -se '.[0][0].uuid == .[1][0].uuid' \
        /var/lib/horizon/access/whitelist.json /var/lib/horizon/access/ops.json > /dev/null
      ${config.virtualisation.docker.package}/bin/docker volume create horizon_data > /dev/null
      install -d -m0750 -o ${id} -g ${id} ${volume}
      install -m0640 -o ${id} -g ${id} ${settings} ${volume}/server.toml
      printf 'eula=true\n' > ${volume}/eula.txt
      chown ${id}:${id} ${volume}/eula.txt
      # Restore the owner-only policy on every start. A missing or malformed
      # policy fails closed instead of creating an unrestricted server.
      for file in whitelist.json ops.json; do
        install -m0640 -o ${id} -g ${id} \
          /var/lib/horizon/access/"$file" ${volume}/"$file"
      done
    '';
  };
}
