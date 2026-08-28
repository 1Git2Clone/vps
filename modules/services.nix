# ==============================================================================
# Services
# ==============================================================================
{ config, ... }:

{
  services = {
    openssh.enable = true;
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
