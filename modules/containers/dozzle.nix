# ==============================================================================
# Dozzle — log viewer
# ==============================================================================
# Reachable on :8080 from the tailnet only: published ports arrive through the
# forward chain, and 8080 is not in its internet allow-list (see
# modules/firewall.nix).
#
# Dozzle's simple auth provider cannot hash a plaintext password — it reads a
# bcrypt hash from users.yml in its data directory. Generate the hash once:
#
#   docker run -it --rm amir20/dozzle:v10.7.1 generate hutao \
#     --password '<password>' --email you@example.com --name 'Ivan'
#
# and put the `password:` value in secrets.yaml as dozzle/admin_password_hash.
{ config, ... }:

let
  usersFile = "/var/lib/dozzle/users.yml";
in
{
  sops.templates."dozzle-users.yml".content = ''
    users:
      ${config.sops.placeholder.dozzle_admin_user}:
        name: ${config.sops.placeholder.dozzle_admin_user}
        email: ${config.infra.acmeEmail}
        password: ${config.sops.placeholder.dozzle_admin_password_hash}
  '';

  # A rendered sops template lives under a generation directory that changes
  # whenever secrets are re-installed, and `path` only symlinks to it. Docker
  # resolves a symlink at mount time and then holds that inode forever, so a
  # changed hash would never reach the container. Copying to a stable path is
  # what makes the mount durable.
  systemd.services.dozzle-users = {
    description = "Install the dozzle users file";
    requiredBy = [ "docker-dozzle.service" ];
    before = [ "docker-dozzle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -D -m 0600 -o root -g root \
        ${config.sops.templates."dozzle-users.yml".path} ${usersFile}
    '';
  };

  virtualisation.oci-containers.containers.dozzle = {
    image = "amir20/dozzle:v10.7.1";

    ports = [ "8080:8080" ];

    environment.DOZZLE_AUTH_PROVIDER = "simple";

    volumes = [
      # Read-only: dozzle only ever reads container logs, and a writable docker
      # socket is root on the host.
      "/var/run/docker.sock:/var/run/docker.sock:ro"
      "dozzle_data:/data"
      # Nested inside the volume above. Docker orders bind mounts by
      # destination depth, so the volume is mounted first and this file lands
      # on top of it — which is how a generated file gets into a named volume.
      "${usersFile}:/data/users.yml:ro"
    ];

    # Hardening baseline. Still root: the docker socket is srw-rw---- root:docker
    # and dozzle reads it as the owner, so no capability is needed for that —
    # but dropping caps means it cannot do anything else with being root.
    extraOptions = [
      "--read-only"
      "--security-opt=no-new-privileges:true"
      "--cap-drop=ALL"
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m"
    ];
  };
}
