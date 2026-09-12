# ==============================================================================
# Uptime Kuma — status page
# ==============================================================================
# Reached only through caddy, at status.<domain>. It publishes no port.
#
# NOTE ON THE ADMIN ACCOUNT: uptime-kuma has no environment variable or config
# file that seeds it — the first visitor to the fresh instance is prompted to
# create the account, and after that the setup route is closed. So unlike
# grafana and dozzle there is nothing to put in sops here; create the account
# immediately after the first deploy, before anyone else can.
#
# The self-hosted-status-page paradox is that it cannot report the one outage
# that matters most: its own host being down. kuma-check closes that — a timer
# probes the public page and pings healthchecks.io, so silence is the alert.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain proxyNetwork;
  pingUrlFile = config.sops.secrets.kuma_healthcheck_url.path;

  # /api/entry-page rather than the site root: the root answers 302 and only
  # this backend route answers 200 directly, so probing the root would read as
  # a failure forever.
  checkUrl = "https://status.${domain}/api/entry-page";

  kumaCheck = pkgs.writeShellApplication {
    name = "kuma-check";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      # No retry logic by design: one bad probe is a data point, and the next
      # run is five minutes away.
      ping_url=$(cat ${pingUrlFile})
      [ -n "$ping_url" ] || exit 0

      code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' ${checkUrl} || echo 000)

      case "$code" in
        2??) curl -fsS -m 10 -o /dev/null "$ping_url" ;;
        *) curl -fsS -m 10 -o /dev/null --data-raw "HTTP $code" "$ping_url/fail" ;;
      esac
    '';
  };
in
{
  virtualisation.oci-containers.containers.kuma = {
    # Bump with: curl -sS 'https://hub.docker.com/v2/repositories/louislam/uptime-kuma/tags?page_size=20&ordering=last_updated'
    image = "louislam/uptime-kuma:2.5.4";
    volumes = [ "kuma_data:/app/data" ];
    networks = [ proxyNetwork ];
  };

  systemd.services.kuma-check = {
    description = "Probe the public status page and report to healthchecks.io";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe kumaCheck;
    };
  };

  systemd.timers.kuma-check = {
    description = "Probe the public status page every five minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = false;
      RandomizedDelaySec = "30s";
    };
  };
}
