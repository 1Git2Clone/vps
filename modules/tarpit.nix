# ==============================================================================
# SSH tarpit — endlessh-go, and the prometheus that counts it
# ==============================================================================
# Bots find sshd on 2222 thousands of times a week and give up at "Invalid
# user". This gives them somewhere worse to be: endlessh-go accepts the
# connection and trickles an endless pre-banner at them, one random line a
# second, so a client that waits for the SSH version string waits for hours.
# It is not a defence (sshd is key-only either way); it is a scoreboard.
#
# THE PORTS are three common alternative SSH ports: 222, 2022 and 22222. Which
# one bots like best is what the dashboard's port split is for. Not 22
# (forgejo's) and not 2222 (the real sshd, and endlessh-go's own default —
# which is why `port` is always set here). A port
# is opened in THREE places: here, the input chain in modules/firewall.nix and
# tofu/modules/hetzner-firewall. A host service, so input, not forward.
#
# 222 is the module's `port` because the module grants CAP_NET_BIND_SERVICE
# only when `port` (or the prometheus port) is below 1024; a privileged port
# passed through extraOptions alone would fail to bind.
#
# THE MAP. -geoip_supplier=ip-api looks each new client up at ip-api.com over
# plain http (80 is already open in the output chain), which is what gives the
# dashboard's geomap its points. It sends bot addresses to a third party, and
# nothing else. ip-api's free tier allows 45 lookups a minute; past that a
# client is still trapped, it just has no location.
#
# prometheus exists for this alone: grafana had only tempo. Both it and the
# exporter bind loopback, and grafana (host networking) reads it at
# localhost:9090. Its data is a 15-day window of bot statistics and is not in
# the restic set on purpose.
{
  services.endlessh-go = {
    enable = true;
    port = 222;
    extraOptions = [
      "-port=2022"
      "-port=22222"
      "-geoip_supplier=ip-api"
    ];
    # ponytail: one series per client address, kept until the service restarts
    # (-prometheus_clean_unseen_seconds=0, the default). At ~250 new addresses
    # a day that is a few MB a month; set that flag if prometheus ever grows.
    prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
    };
  };

  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    scrapeConfigs = [
      {
        job_name = "endlessh";
        static_configs = [ { targets = [ "127.0.0.1:2112" ]; } ];
      }
    ];
  };
}
