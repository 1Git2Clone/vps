# ==============================================================================
# SearXNG — metasearch
# ==============================================================================
# Publishes no port. Reached only through caddy at search.<domain>, like kuma.
#
# NOTE ON AUTHENTICATION: searxng has no accounts of its own — no admin user, no
# login, nothing to seed. Access control is entirely the proxy's job, so the
# credential for this service lives in caddy's site block as basic_auth and the
# bcrypt hash is in sops. See modules/containers/caddy.nix.
#
# That is also why `limiter` is off below. The limiter exists to keep a PUBLIC
# instance from being scraped, and it requires a valkey/redis to hold its
# counters — a whole second container for a site that already refuses anyone
# without the password.
{ config, pkgs, ... }:

let
  inherit (config.infra) domain proxyNetwork;

  # use_default_settings merges this ON TOP of the image's own settings.yml, so
  # only the departures from upstream need to be here. Spelling out the full
  # file instead would mean re-reviewing every upstream default on each image
  # bump — a settings.yml pinned to last year's engine list is how a metasearch
  # instance quietly stops returning results.
  settings = pkgs.writeText "searxng-settings.yml" ''
    use_default_settings: true

    general:
      instance_name: "hu-tao search"
      # Nothing to donate to and no separate contact address; both render as
      # dead links in the UI footer otherwise.
      donation_url: false
      contact_url: false

    search:
      autocomplete: "duckduckgo"
      # html only. The json format is what scrapers and third-party frontends
      # consume, and this instance is for a browser.
      formats:
        - html

    server:
      # secret_key is NOT set here. It comes from SEARXNG_SECRET in the
      # environment (sops), because everything in this file becomes a Nix store
      # path and the store is world-readable. Left out entirely rather than
      # given a placeholder value: upstream's own default is the literal string
      # "ultrasecretkey", so a placeholder here would be indistinguishable from
      # having forgotten to override it.
      base_url: "https://search.${domain}/"

      # See the header. basic_auth in caddy is what stands in for this.
      limiter: false

      # Images are fetched by searxng and re-served, so a result thumbnail
      # never makes the browser talk to the upstream engine directly.
      image_proxy: true
  '';
in
{
  sops.templates."searxng.env".content = ''
    SEARXNG_SECRET=${config.sops.placeholder.searxng_secret_key}
  '';

  virtualisation.oci-containers.containers.searxng = {
    image = "searxng/searxng:2026.9.12-d4f00d15d";

    environmentFiles = [ config.sops.templates."searxng.env".path ];

    volumes = [
      "${settings}:/etc/searxng/settings.yml:ro"
      # A named volume, so services.restic picks it up with no edit to
      # modules/backups.nix. It holds the fetched favicon and image cache only;
      # there is no user data in searxng to lose.
      "searxng_data:/var/cache/searxng"
    ];

    networks = [ proxyNetwork ];

    # Not the fuller lockdown caddy and dozzle carry: the image's entrypoint
    # chowns /var/cache/searxng to its own uid on start, which needs both a
    # writable root filesystem and CAP_CHOWN. This flag is orthogonal to that
    # and costs nothing.
    extraOptions = [ "--security-opt=no-new-privileges:true" ];
  };
}
