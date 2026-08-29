# ==============================================================================
# Cloudflared — tunnel daemon
# ==============================================================================
# The tunnel is connected but nothing routes through it: git/music/mail/smtp are
# unproxied A records straight at this host, so caddy serves them directly.
# Routes and ingress live in Cloudflare, managed from tofu/ — not here.
{ config, ... }:

{
  sops.templates."cloudflared.env".content = ''
    TUNNEL_TOKEN=${config.sops.placeholder.cloudflare_tunnel_token}
  '';

  virtualisation.oci-containers.containers.cloudflared = {
    image = "cloudflare/cloudflared:2026.8.2";

    # The token is passed by environment rather than on the command line: an
    # argv is readable by every process on the host, an env file is not.
    environmentFiles = [ config.sops.templates."cloudflared.env".path ];

    cmd = [
      "tunnel"
      "--no-autoupdate"
      "run"
    ];

    networks = [ config.infra.proxyNetwork ];
  };
}
