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
    # Hardening baseline. No --user here: this container still runs as root,
    # and its writable state lives in a docker volume that root owns. Changing
    # the account would need that volume chowned, which is a migration, not a
    # flag. See modules/containers/caddy.nix for the full treatment.
    extraOptions = [
      "--read-only"
      "--security-opt=no-new-privileges:true"
      "--cap-drop=ALL"
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m"
    ];
  };
}
