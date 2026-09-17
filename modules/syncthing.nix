# ==============================================================================
# Syncthing
# ==============================================================================
# On the old box this ran as a *user* service with its state in
# ~/.config/syncthing and its folders under ~/syncthing. Both paths are kept
# byte-identical here, for two reasons:
#
#   * navidrome bind-mounts ~/syncthing/Music (11G) as its library. Move the
#     folder root and navidrome comes up with an empty library and no error.
#   * A syncthing node's device ID is derived from the TLS keypair in the config
#     directory. Migrating that directory keeps the identity, so every already-
#     paired device keeps working. Generate a fresh one and you re-pair by hand
#     on every phone and laptop.
{ config, ... }:

{
  services.syncthing = {
    enable = true;

    user = "hutao";
    group = "users";

    dataDir = "/home/hutao/syncthing";
    configDir = "/home/hutao/.config/syncthing";

    # BOTH OF THESE DEFAULT TO TRUE, AND THE DEFAULT IS DESTRUCTIVE HERE.
    # With them on, syncthing's declared device/folder list becomes the whole
    # truth and everything configured through the GUI is deleted on start — so
    # a migrated config directory would be silently emptied and every peer
    # unpaired. Nothing about devices or folders is declared in this repo, so
    # the existing config must be left alone.
    overrideDevices = false;
    overrideFolders = false;

    # 0.0.0.0, restricted by the firewall rather than by the bind address —
    # the same arrangement as grafana:3000 and tempo's OTLP ports. The input
    # chain reaches it from `iifname tailscale0` and, since the GUI also answers
    # at syncthing.<domain>, from the caddy container on the docker bridge.
    #
    # That proxy needs one thing from this end and gets it in the Caddyfile
    # instead: syncthing refuses a request whose Host header is not localhost or
    # a bare address, so caddy rewrites Host to the upstream. The alternative,
    # insecureSkipHostcheck, lives in the config directory below — which this
    # module deliberately does not own, so it would be a hand edit no deploy can
    # reproduce.
    guiAddress = "0.0.0.0:8384";

    # Deliberately NOT opening 22000/21027. The Hetzner edge firewall has never
    # allowed them either, so this box has always synced over relays and the
    # tailnet — opening them now would be a change in exposure, not a fix.
    openDefaultPorts = false;
  };

  # The folder contents are replicated across every paired device by definition,
  # so they do not need a restic snapshot. The config directory is the opposite:
  # it is small, it exists once, and losing it costs a manual re-pair everywhere.
  services.restic.backups.b2.paths = [ "/home/hutao/.config/syncthing" ];
}
