# ==============================================================================
# SillyTavern — chat frontend, reached only through the tailnet Caddy listener
# ==============================================================================
{
  config,
  lib,
  pkgs,
  sillytavernExtensions,
  ...
}:

let
  # Copy rather than symlink: neither the Nix store nor links into it are
  # available inside the container, and extensions may write beside their code.
  seeds = pkgs.runCommand "sillytavern-extension-seeds" { nativeBuildInputs = [ pkgs.jq ]; } (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: src: ''
        mkdir -p "$out/${name}"
        cp -R ${src}/. "$out/${name}/"
        chmod -R u+w "$out/${name}"
        jq '.auto_update = false' "$out/${name}/manifest.json" > "$out/${name}/manifest.json.tmp"
        mv "$out/${name}/manifest.json.tmp" "$out/${name}/manifest.json"
        printf '%s\n' '${src}' > "$out/${name}/.nix-src"
      '') sillytavernExtensions
    )
  );
  docker = "${config.virtualisation.docker.package}/bin/docker";
in
{
  # Runs while the container is stopped, before Docker starts it. Inspect the
  # volume rather than assuming Docker's data-root. Copies are owned by root,
  # matching this image's current default runtime user; no ownership migration
  # of the already-deployed user data is needed.
  systemd.services.docker-sillytavern.preStart = lib.mkBefore ''
    ${docker} volume create sillytavern_extensions >/dev/null
    extensionRoot="$(${docker} volume inspect --format '{{.Mountpoint}}' sillytavern_extensions)"
    ${pkgs.coreutils}/bin/env PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
      ]
    } \
      ${pkgs.bash}/bin/bash ${../../scripts/seed-sillytavern-extensions.sh} ${seeds} "$extensionRoot"
  '';

  virtualisation.oci-containers.containers.sillytavern = {
    image = "ghcr.io/sillytavern/sillytavern:1.19.0@sha256:eef27ff0c7961f1a2f488400f581f48ff38f8b910c5d3b8d389138d71791bb14";

    # No published port. Only Caddy's fixed proxy-network address may connect;
    # forwarded client IPs are deliberately not used for this allow-list.
    networks = [ config.infra.proxyNetwork ];
    environment = {
      NODE_ENV = "production";
      SILLYTAVERN_LISTEN = "true";
      SILLYTAVERN_PORT = "8000";
      SILLYTAVERN_WHITELISTMODE = "true";
      SILLYTAVERN_WHITELIST = builtins.toJSON [ config.infra.caddyIPv4 ];
      SILLYTAVERN_ENABLEFORWARDEDWHITELIST = "false";
      SILLYTAVERN_WHITELISTDOCKERHOSTS = "false";
      SILLYTAVERN_ENABLEUSERACCOUNTS = "true";
    };

    # Upstream copies and migrates config.yaml at startup, so its config
    # directory must be writable. Deployment settings above override that file
    # without blocking migrations. All mutable state is covered by restic.
    volumes = [
      "sillytavern_config:/home/node/app/config"
      "sillytavern_data:/home/node/app/data"
      "sillytavern_plugins:/home/node/app/plugins"
      "sillytavern_extensions:/home/node/app/public/scripts/extensions/third-party"
    ];
  };
}
