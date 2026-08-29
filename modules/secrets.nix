# ==============================================================================
# Secrets
# ==============================================================================
{
  sops = {
    defaultSopsFile = ../secrets.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    # Set in `config.yaml` using SOPS + age:
    #
    # ```sh
    # age-keygen > ~/.sops-nix/key.txt
    # ```
    secrets = {
      # === Main ===
      root_password = {
        neededForUsers = true;
      };
      user_password = {
        neededForUsers = true;
      };

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

      # === Cloudflare ===
      # Used by lego for the ACME DNS-01 challenge (modules/acme.nix). The ACME
      # contact address is NOT here: security.acme needs it at evaluation time,
      # and a registration contact is not a credential — see infra.acmeEmail.
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

      # === Grafana ===
      grafana_admin_user = {
        key = "grafana/admin_user";
      };
      grafana_admin_password = {
        key = "grafana/admin_password";
      };

      # === Kuma ===
      # Only the out-of-band probe. uptime-kuma itself has no way to seed its
      # admin account — that is a one-time first-visit setup.
      kuma_healthcheck_url = {
        key = "kuma/healthcheck_url";
      };

      # === Minecraft ===
      minecraft_rcon_password = {
        key = "minecraft/rcon_password";
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
}
