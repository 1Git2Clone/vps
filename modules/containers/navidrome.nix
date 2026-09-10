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
    image = "deluan/navidrome:0.63.2";

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
