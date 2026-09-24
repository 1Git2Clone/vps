# ==============================================================================
# Navidrome — music server
# ==============================================================================
# Bound to loopback: reached through caddy on the proxy network, never directly,
# so 4533 never needs a firewall rule.
{ config, ... }:

{
  # Last.fm. Both halves come from one application registration at
  # https://www.last.fm/api/account/create. The API key is nominally the public
  # half, but the pair is what identifies this instance and the secret signs its
  # requests, so both live in sops and neither reaches the Nix store.
  #
  # This does NOT by itself scrobble anything. LastFM.Enabled defaults to true,
  # so the credentials are all the SERVER needs — but each user still has to
  # authorise their own Last.fm account under Personal Settings -> "Scrobble to
  # Last.fm", which is an OAuth round trip navidrome cannot make for them. A
  # deploy that looks clean and scrobbles nothing is almost always this step.
  sops.templates."navidrome.env" = {
    content = ''
      ND_LASTFM_APIKEY=${config.sops.placeholder.navidrome_lastfm_api_key}
      ND_LASTFM_SECRET=${config.sops.placeholder.navidrome_lastfm_secret}
    '';

    # Rotating either value changes only the CONTENT of the rendered env file.
    # Its path is stable, so the unit text is byte-identical and
    # switch-to-configuration finds nothing to restart — the container would
    # keep serving with the old credentials in its environment until something
    # unrelated happened to recreate it. sops-nix diffs the rendered file and
    # restarts this unit only when it actually changed, so a no-op deploy still
    # does not interrupt playback.
    restartUnits = [ "docker-navidrome.service" ];
  };

  virtualisation.oci-containers.containers.navidrome = {
    # 0.64.1, a security release: failed Subsonic logins were never throttled,
    # so passwords could be brute-forced at full speed (GHSA-p994-r776-mw52,
    # high), plus an SSRF and a local file read through M3U playlist artwork,
    # player takeover by any signed-in user, and a library filter missing on
    # three endpoints. No migration of its own.
    #
    # 0.64.0 before it re-encodes every internal ID to a canonical 128-bit base62 form.
    # Upstream: "The migration touches every table, so back up your database
    # before upgrading." navidrome_data is that database, and the rewrite is
    # one-way — re-deploying the previous generation runs 0.63.2 against IDs it
    # cannot read, so the rollback here is a restic restore of navidrome_data.
    #
    # The library itself is never at risk: /music is a read-only bind mount
    # (below) and holds no navidrome state. Worst case is a restore plus a
    # rescan. Clients that cached item IDs — offline downloads — re-sync once.
    #
    # Bump with: curl -sS 'https://hub.docker.com/v2/repositories/deluan/navidrome/tags?page_size=20&ordering=last_updated'
    image = "deluan/navidrome:0.64.1";

    ports = [ "127.0.0.1:4533:4533" ];

    # An env FILE, not `environment`: everything in `environment` becomes a
    # `-e` argument in the unit, and the unit is a world-readable store path.
    environmentFiles = [ config.sops.templates."navidrome.env".path ];

    volumes = [
      "navidrome_data:/data"
      # The library itself stays a host bind mount — it is synced onto this box
      # by syncthing and is not this system's data to own. Read-only: navidrome
      # has no business writing to it.
      "/home/hutao/syncthing/Music:/music:ro"
    ];

    networks = [ config.infra.proxyNetwork ];
  };
}
