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
    fail2ban = {
      enable = true;

      bantime = "1h";
      maxretry = 5;
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "100.64.0.0/10" # tailscale CGNAT
      ];

      jails = {
        DEFAULT.settings.findtime = "10m";

        sshd = {
          enabled = true;
          settings = {
            port = 22;
            backend = "systemd";
            maxretry = 3;
            findtime = "15m";
            bantime = "2h";
          };
        };
        # TODO: Add:
        # ```nix
        # jails.forgejo-ssh = {
        #   filter.Definition.failregex = ''...'';   # generates filter.d/forgejo-ssh.conf
        #   settings = {
        #     port = 22;
        #     backend = "systemd";
        #     journalmatch = "CONTAINER_TAG=forgejo";
        #     banaction = config.services.fail2ban.banaction-allports;
        #     chain = "DOCKER-USER";
        #     maxretry = 3;
        #     bantime = "24h";
        #   };
        # };
        # ```
        # When the actual containers are being provisioned
      };
    };
  };
  virtualisation.docker.enable = true;
}
