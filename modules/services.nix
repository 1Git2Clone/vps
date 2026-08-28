# ==============================================================================
# Services
# ==============================================================================
{ config, ... }:

{
  services = {
    openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PubkeyAuthentication = true;
        X11Forwarding = false;
        UsePAM = true;
      };
    };
    tailscale = {
      enable = true;
      authKeyFile = config.sops.secrets.tailscale_authkey.path;
      extraUpFlags = [
        "--ssh"
      ];
    };
  };
  virtualisation.docker.enable = true;
}
