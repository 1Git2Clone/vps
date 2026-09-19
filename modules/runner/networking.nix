# ==============================================================================
# The runner's hostname and the one way in
# ==============================================================================
# Not modules/services.nix, which this replaces for this host. That module
# enables tailscale from a sops authKeyFile and runs a fail2ban jail against a
# forgejo container's journal — neither applies here, and the tailnet is
# actively excluded (see runner/configuration.nix).
#
# sshd is on 22, not the VPS's 2222, because nothing on this box publishes 22 —
# there is no forgejo container to yield it to. The source is narrowed at the
# cloud firewall instead: `runner-firewall` admits tcp/22 from
# 167.233.24.58/32 alone, so the only host that can knock is the VPS, and the
# admin path is `ssh -J vps root@46.225.61.172`.
#
# PermitRootLogin is "prohibit-password", which differs from the VPS's "no".
# Two reasons, both about this being a disposable box rebuilt from an image:
# nixos-anywhere targets root@, and a re-install is the ordinary way to change
# this machine rather than an emergency. It is key-only either way —
# PasswordAuthentication is off — and the cloud firewall means the only client
# that can reach the port is a box whose own root keys are the same set.
{ config, ... }:

{
  networking = {
    # Baked into the snapshot, so every clone comes up with this name. Forgejo
    # tells its runners apart by the uuid it issues at registration, not by
    # name, so duplicates are a cosmetic problem in Site Administration ->
    # Actions -> Runners and nothing more. Prune stale records by hand.
    hostName = "forgejo-runner";
    domain = config.infra.domain;

    # The ruleset lives in modules/runner/firewall.nix. Declared here as false
    # so that enabling nftables there cannot silently coexist with the
    # iptables-based default.
    firewall.enable = false;
  };

  services.openssh = {
    enable = true;
    ports = [ 22 ];
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PubkeyAuthentication = true;
      X11Forwarding = false;
      UsePAM = true;
    };
  };
}
