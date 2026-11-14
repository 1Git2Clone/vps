# ==============================================================================
# SillyTavern — chat frontend, reached only through the tailnet Caddy listener
# ==============================================================================
{ config, ... }:

{
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
