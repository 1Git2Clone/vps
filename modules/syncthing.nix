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
    # THE HOST CHECK IS NOT RUNNING AT THIS BIND ADDRESS, and an earlier version
    # of this comment claimed the opposite. lib/api/api.go installs
    # localhostMiddleware only `if addressIsLocalhost(guiCfg.Address())`, and
    # that predicate ends in `ip.IsLoopback()`. 0.0.0.0 is not loopback, so the
    # middleware is never installed and caddy's rewriteHost is currently a
    # no-op. Two consequences worth keeping straight:
    #
    #   * Nothing here rejects a container on a docker bridge that addresses
    #     this API directly at 172.17.0.1:8384. The GUI password below is what
    #     stops it, which is exactly why it is declared rather than assumed.
    #   * Narrowing this to 127.0.0.1 — the obvious hardening — switches the
    #     middleware ON, and caddy's rewrite to a bare upstream address would
    #     then 403 with "Host check error". In syncthing 2.x a bare IP no
    #     longer satisfies the check; only loopback does. Do that one with
    #     insecureSkipHostcheck in the same change, or not at all.
    guiAddress = "0.0.0.0:8384";

    # THE ONE CREDENTIAL THIS MODULE USED TO LEAVE TO THE CONFIG DIRECTORY.
    # Every other exposed service in this repo declares its own; syncthing did
    # not, because the config directory was migrated from the old box with a
    # password already set by hand. That works until the day it does not: a
    # restore, a reset, or a rebuild onto fresh state brings syncthing up with a
    # generated apikey and NO password (IsAuthEnabled() is `len(User) > 0 &&
    # len(Password) > 0`, and prepare() sets neither), bound to 0.0.0.0 and
    # reachable from six containers — with nothing in the deploy to notice.
    #
    # The API is not a viewer: /rest/config/folders takes a versioning block
    # with `type = "external"` and a `params.command` that syncthing execs, and
    # a folder path of ~/.ssh writes authorized_keys as hutao, who has
    # passwordless sudo. So this is the difference between a login form and
    # root, and it now fails closed on every deploy.
    #
    # guiPasswordFile, not settings.gui.password: the module reads this file at
    # runtime, bcrypts it with mkpasswd and PATCHes /rest/config/gui, so the
    # plaintext never reaches the nix store. PATCH also merges, so the theme,
    # apikey and tls fields in the migrated config survive — a PUT via
    # settings.gui would replace the whole object and drop them.
    guiPasswordFile = config.sops.secrets.syncthing_gui_password.path;

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
