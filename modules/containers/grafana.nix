# ==============================================================================
# Grafana — dashboards
# ==============================================================================
# Host networking on :3000, tailnet-only: 3000 is not in the firewall's input
# allow-list, and the tailscale0 interface is accepted wholesale.
#
# Anonymous Admin access, which the ansible compose had, is off. The login is a
# real one backed by sops.
{ config, pkgs, ... }:

let
  # tempo is on host networking too, hence localhost rather than a container
  # name — grafana is not on the proxy network and cannot use docker DNS.
  datasource = pkgs.writeText "tempo.yaml" ''
    apiVersion: 1
    datasources:
      - name: Tempo
        type: tempo
        uid: tempo
        access: proxy
        url: http://localhost:3200
        isDefault: true
        jsonData:
          httpMethod: GET
  '';
in
{
  sops.templates."grafana.env".content = ''
    GF_SECURITY_ADMIN_USER=${config.sops.placeholder.grafana_admin_user}
    GF_SECURITY_ADMIN_PASSWORD=${config.sops.placeholder.grafana_admin_password}
  '';

  virtualisation.oci-containers.containers.grafana = {
    # Pinned to a patch, and the change is a PIN rather than an upgrade:
    # `13.0` is a FLOATING tag. On 2026-09-12 it and `13.0.8` resolved to the
    # same digest (sha256:a21e4b8b9cd2...), so this box has silently been
    # tracking every 13.0.x — running each one's migrations on first start —
    # without a line in this file ever changing. Reproducibility is the whole
    # point of the repo, so the version is now written down.
    #
    # Bump with: curl -sS 'https://hub.docker.com/v2/repositories/grafana/grafana/tags?page_size=20&ordering=last_updated'
    image = "grafana/grafana:13.0.8";

    environment = {
      GF_AUTH_ANONYMOUS_ENABLED = "false";
      # Grafana would otherwise let an unauthenticated visitor create an
      # account on a box whose port is only meant to be tailnet-reachable.
      GF_USERS_ALLOW_SIGN_UP = "false";
    };

    environmentFiles = [ config.sops.templates."grafana.env".path ];

    volumes = [
      # The single file rather than the whole provisioning directory: grafana
      # ships the rest of that tree, and mounting over it would hide it.
      "${datasource}:/etc/grafana/provisioning/datasources/tempo.yaml:ro"
      # The image chowns /var/lib/grafana to uid 472 and declares it a VOLUME,
      # so a fresh named volume inherits that ownership.
      "grafana_data:/var/lib/grafana"
    ];

    extraOptions = [ "--network=host" ];
  };

  systemd.services.docker-grafana.after = [ "docker-tempo.service" ];
}
