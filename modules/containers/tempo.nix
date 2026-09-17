# ==============================================================================
# Tempo — trace storage
# ==============================================================================
# Host networking. The OTLP receivers bind 0.0.0.0 and the nftables input chain
# is what keeps them private: 4317/4318 are absent from the public allow-list,
# and `iifname tailscale0 accept` is what lets the tailnet reach them. Grafana on
# :3000 has always been protected exactly this way.
#
# This used to bind a hardcoded tailnet address, which is a trap when the host is
# replaced: a new machine is a new tailscale node with a new address, so the
# literal goes stale and tempo dies on "cannot assign requested address" —
# pointing at the collector rather than at the migration that caused it.
{ pkgs, ... }:

let
  dataPath = "/var/tempo";

  # From the Nix store: 0444, so uid 10001 can read it without the 0644-vs-0640
  # dance a bind-mounted host file needed. Its store path changes with its
  # content, so systemd recreates the container when the config changes.
  configFile = pkgs.writeText "tempo.yaml" ''
    server:
      http_listen_port: 3200

    # TraceQL metrics queries are capped at 24h by default, and grafana's
    # "Last 24 hours" sends a range a few seconds over that — so the preset
    # that looks like it should work is exactly the one that 400s. A week is
    # the window where this bot's traffic forms a shape worth plotting.
    query_frontend:
      metrics:
        max_duration: 168h

    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318

    live_store:
      shutdown_marker_dir: ${dataPath}/live-store/shutdown-marker
      wal:
        path: ${dataPath}/live-store/traces

    storage:
      trace:
        backend: local
        local:
          path: ${dataPath}/blocks
        wal:
          path: ${dataPath}/wal
  '';
in
{
  virtualisation.oci-containers.containers.tempo = {
    # Pinned to the 3.0.0 release, not `latest` — `latest` is a main-branch
    # build, so the tag reports a version that was never released.
    #
    # Bump with: curl -sS 'https://hub.docker.com/v2/repositories/grafana/tempo/tags/<version>'
    # and NOT the tag LISTING: grafana/tempo publishes enough tags that every
    # 3.x falls outside the 100 most-recently-updated, so a listing looks like
    # 3.x does not exist at all. Ask for the exact tag instead.
    image = "grafana/tempo:3.0.3";

    cmd = [ "-config.file=/etc/tempo.yaml" ];

    volumes = [
      "${configFile}:/etc/tempo.yaml:ro"
      # The image creates /var/tempo owned by uid 10001, and docker copies that
      # ownership onto a fresh named volume — so tempo can write to it without
      # anything on the host chowning anything.
      "tempo_data:${dataPath}"
    ];

    extraOptions = [
      "--network=host"

      # Hardening baseline. Tempo already runs as uid 10001 from the image and
      # writes only to its volume, so read-only costs it nothing.
      "--read-only"
      "--security-opt=no-new-privileges:true"
      "--cap-drop=ALL"
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m"
    ];
  };
}
