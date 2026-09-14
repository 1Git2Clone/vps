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

      # === Forgejo ===
      # The Actions runner's own secret, from Site Administration -> Actions ->
      # Runners -> Create new runner, which creates the runner record and shows
      # its uuid and secret. The uuid is not secret and is in
      # modules/containers/forgejo-runner.nix; this is the half that is.
      #
      # NOT a registration token: `forgejo-runner register` and the .runner file
      # it writes are the legacy path, and a declared server.connections entry
      # and a .runner file cannot coexist.
      #
      # A missing key here fails sops-install-secrets, which fails the BUILD —
      # so add the value before the deploy that first imports this module.
      forgejo_runner_token = {
        key = "forgejo/runner_token";
      };

      # === Grafana ===
      grafana_admin_user = {
        key = "grafana/admin_user";
      };
      grafana_admin_password = {
        key = "grafana/admin_password";
      };

      # === Vuln Scan ===
      vuln_scan_discord_webhook_url = {
        key = "vuln_scan/discord_webhook_url";
      };

      # === Kuma ===
      # Only the out-of-band probe. uptime-kuma itself has no way to seed its
      # admin account — that is a one-time first-visit setup.
      kuma_healthcheck_url = {
        key = "kuma/healthcheck_url";
      };

      # === SearXNG ===
      # Signs session cookies. Upstream's default is the literal string
      # "ultrasecretkey", so an unset one is not an empty key — it is a
      # published key.
      searxng_secret_key = {
        key = "searxng/secret_key";
      };
      # Read by CADDY, not by searxng: the service has no accounts of its own,
      # so basic_auth on the site is the entire access control. See
      # modules/containers/caddy.nix.
      searxng_admin_user = {
        key = "searxng/admin_user";
      };
      searxng_admin_password_hash = {
        key = "searxng/admin_password_hash";
      };

      # === Minecraft ===
      # One per world: the two RCON consoles are separate on purpose, so a
      # password that leaks reaches one world rather than both.
      minecraft_rcon_password = {
        key = "minecraft/rcon_password";
      };
      minecraft2_rcon_password = {
        key = "minecraft2/rcon_password";
      };

      # === Navidrome ===
      # One Last.fm application registration, from
      # https://www.last.fm/api/account/create. Reaches the container as
      # ND_LASTFM_APIKEY / ND_LASTFM_SECRET — see
      # modules/containers/navidrome.nix, which also carries the restartUnits
      # that make a rotation actually take effect.
      navidrome_lastfm_api_key = {
        key = "navidrome/lastfm/api_key";
      };
      navidrome_lastfm_secret = {
        key = "navidrome/lastfm/secret";
      };

      # === Email ===
      email_postmaster = {
        key = "email/postmaster";
      };
      email_dkim_private_key = {
        key = "email/dkim_private_key";
      };
      # Roundcube encrypts the logged-in user's password into its session with
      # this. The image GENERATES A RANDOM ONE when the variable is unset, so it
      # changes every time the container is recreated — i.e. on every deploy —
      # and every existing session silently loses the password it needs to
      # authenticate to submission. Sending then fails with
      # "554 5.7.1 Client host rejected: Access denied" while receiving is fine.
      email_roundcube_des_key = {
        key = "email/roundcube_des_key";
      };

      # === Bootstrap ===
      tailscale_authkey = { };
    };
  };
}
