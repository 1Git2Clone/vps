# ==============================================================================
# Navidrome — music server
# ==============================================================================
# Bound to loopback: reached through caddy on the proxy network, never directly,
# so 4533 never needs a firewall rule.
{ config, ... }:

{
  virtualisation.oci-containers.containers.navidrome = {
    image = "deluan/navidrome:0.63.2";

    ports = [ "127.0.0.1:4533:4533" ];

    volumes = [
      "navidrome_data:/data"
      # The library itself stays a host bind mount — it is synced onto this box
      # by syncthing and is not this system's data to own. Read-only: navidrome
      # has no business writing to it.
      "/home/hutao/syncthing/Music:/music:ro"
    ];

    networks = [ config.infra.proxyNetwork ];
  };
}
