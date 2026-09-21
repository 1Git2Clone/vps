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

      # === Syncthing ===
      # The PLAINTEXT GUI password. The nixos module bcrypts it at runtime with
      # mkpasswd and PATCHes /rest/config/gui, so the hash is what lands in
      # config.xml and neither form ever enters the nix store.
      #
      # owner, because syncthing-init runs as services.syncthing.user (hutao),
      # not root, and reads this file directly.
      syncthing_gui_password = {
        key = "syncthing/gui_password";
        owner = "hutao";
      };

      # === Dozzle ===
      dozzle_admin_user = {
        key = "dozzle/admin_user";
      };
      dozzle_admin_password_hash = {
        key = "dozzle/admin_password_hash";
      };

      # === Forgejo ===
      # NOTHING HERE. The runner secret used to live at forgejo/runners, read
      # by the in-container runner on this box. That runner is gone and the key
      # has no reader left, so the declaration is removed rather than kept
      # "just in case": a declared sops secret is decrypted onto this machine
      # at activation, and a credential nothing consumes is pure exposure.
      #
      # The key may stay in secrets.yaml as operator inventory — sops-nix only
      # looks up what is declared here, so an extra key costs nothing. The CI
      # runners on their own boxes cannot read this file at all: they hold no
      # age key and decrypt nothing, asserted by checks.runner-has-no-secrets.
      # Each one gets its uuid+secret from its own Hetzner user_data, or from a
      # file staged at install for a box that predates that mechanism. See
      # modules/runner/identity.nix.

      # HMAC secret for the Forgejo SYSTEM webhook that pokes pages-pull, set by
      # hand in Site Administration → Integrations → Webhooks. The same string
      # has to be in both places; nothing can check that for you, and a mismatch
      # shows up as a 403 in `journalctl -u pages-hook` and as a failed delivery
      # in the hook's own history — loud in two places, which is the best
      # available when one of them is a web form.
      #
      # NESTED UNDER system_webhooks/<name>/ rather than flat, because a system
      # webhook is a THING THERE CAN BE SEVERAL OF: /admin/hooks fires for every
      # repository on the instance, so the next one is a sibling here rather
      # than a second flat key that happens to start with the same word. `secret`
      # is a leaf under the hook's own name for the same reason — a hook may
      # later need more than one value.
      forgejo_system_webhooks_pages_pull_secret = {
        key = "forgejo/system_webhooks/pages_pull/secret";
      };

      # === Renovate ===
      # Both were Forgejo Actions secrets until the CI runner moved onto its own
      # untrusted box. A runner this repo explicitly does not trust does not get
      # a bot token with write on repository and issue across hutao/* and
      # skavex/* handed to it once a day — so the job became modules/renovate.nix,
      # a timer on this host, and the credentials became ordinary sops secrets.
      #
      # They could not be migrated by copying: a Forgejo Actions secret is
      # write-only once set, so both were reissued.
      renovate_token = {
        key = "renovate/token";
      };
      renovate_github_com_token = {
        key = "renovate/github_com_token";
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
      # An OAUTH CLIENT SECRET, not a `tskey-auth-` key. Tailscale accepts one
      # in place of an auth key, and the reason to prefer it is that it does not
      # expire: the auth keys it replaces capped out at 90 days, so the box was
      # one forgotten rotation away from being unable to rejoin its own tailnet
      # after a rebuild.
      #
      # Consumed through sops.templates."tailscale-authkey" in
      # modules/services.nix rather than directly, because the query parameters
      # that go with it decide whether this node survives being switched off.
      # See there.
      tailscale_oauth_client_secret = { };
    };
  };
}
