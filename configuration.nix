{ lib, config, ... }:

{
  services.openssh.enable = true;

  # ============================================================================
  # Secrets
  # ============================================================================
  sops = {
    defaultSopsFile = ./secrets.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "~/.sops-nix/key.txt";

    # Set in `config.yaml` using SOPS + age:
    #
    # ```sh
    # age-keygen > ~/.sops-nix/key.txt
    # ```
    secrets = {
      # === Main ===
      root_password = { };
      user_password = { };
      authorized_keys = { };

      # === Backups ===
      backups_restic_repository = {
        key = "backups/restic_repository";
      };
      backups_restic_password = {
        key = "backups/restic_password";
      };
      backups_b2_account_id = {
        key = "backups/b2_account_id";
      };
      backups_b2_account_key = {
        key = "backups/b2_account_key";
      };
      backups_healthcheck_url = {
        key = "backups/healthcheck_url";
      };

      # === Certs ===
      acme_email = { };

      # === Cloudflare ===
      cloudflare_api_token = {
        key = "cloudflare/api_token";
      };
      cloudflare_tunnel_token = {
        key = "cloudflare/tunnel_token";
      };

      # === Dozzle ===
      dozzle_admin_user = {
        key = "dozzle/admin_user";
      };
      dozzle_admin_password_hash = {
        key = "dozzle/admin_password_hash";
      };

      # === Email ===
      email_postmaster = {
        key = "email/postmaster";
      };
      email_dkim_private_key = {
        key = "email/dkim_private_key";
      };

      # === Bootstrap ===
      tailscale_authkey = { };
    };
  };

  # ============================================================================
  # 0. Booting
  # ============================================================================

  boot = {
    loader = {
      # ===
      # Alternative with grub:
      # ===
      #
      # grub = {
      #   enable = true;
      #   efiSupport = true;
      #   efiInstallAsRemovable = true;
      #   device = "nodev";
      # };
      # systemd-boot.enable = false;
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };

  # Let the image builder handle the filesystem device
  fileSystems."/" = {
    fsType = "ext4";
  };

  # ============================================================================
  # 2. User
  # ============================================================================
  users.users.hutao = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  system = {
    # ==========================================================================
    # 3. SSH Keys
    # ==========================================================================
    activationScripts.bootstrapRootAuthorizedKeys = lib.stringAfter [ "users" ] ''
      install -d -m 0700 /root/.ssh
      install -m 0600 \
        ${config.sops.secrets.authorized_keys.path} \
        /root/.ssh/authorized_keys
      chown -R root:root /root/.ssh
    '';
    activationScripts.bootstrapAuthorizedKeys = lib.stringAfter [ "users" ] ''
      install -d -m 0700 /home/hutao/.ssh
      install -m 0600 \
        ${config.sops.secrets.authorized_keys.path} \
        /home/hutao/.ssh/authorized_keys
      chown -R hutao:users /home/hutao/.ssh
    '';

    stateVersion = "26.05";
  };
}
