# ==============================================================================
# oauth2-proxy — the Forgejo sign-in gate
# ==============================================================================
# Publishes no port. Serves auth.<domain> on the tailnet listener, and caddy
# asks it about every request to a site that sets `forgejoLogin` (see
# `forward_auth` in modules/containers/caddy.nix). ONE instance for every gated
# site: one Forgejo OAuth app, one set of secrets, and a session cookie on the
# parent domain, so signing in once covers them all.
#
# WHY: an app with no accounts of its own (searxng) needs a login in front of
# it. caddy's basic_auth was the browser's native password dialog, the one
# login a password manager extension cannot fill. Forgejo's is a normal HTML
# form, and its login rate limit and 2FA come along for free.
#
# WHO GETS IN is decided per site, not here. Any Forgejo account can finish the
# sign-in (sign-up is closed, but the renovate bot is an account), so this
# instance admits every signed-in user (`--email-domain=*`) and each gated site
# sends its own list as `?allowed_emails=` on the check. That list is
# `infra.forgejoLoginEverywhere` plus the site's own, so it is never empty — an
# empty one would mean "any account". See modules/options.nix.
#
# THE FLOW, for a gated site with no session:
#   1. caddy's forward_auth asks /oauth2/auth here and gets 401.
#   2. caddy proxies that same request to /oauth2/start, with the full
#      original URL in X-Auth-Request-Redirect. A `redir` to
#      `auth.<domain>/oauth2/start?rd={uri}` would be shorter, but caddy does
#      not escape `{uri}`, so a search's query would be cut at its first `&`.
#   3. /oauth2/start sets the CSRF cookie on the parent domain and sends the
#      browser to Forgejo's authorize page.
#   4. Forgejo sends it back to auth.<domain>/oauth2/callback, the ONE redirect
#      URI registered on the Forgejo app, which sets the session cookie and
#      returns the browser to the URL from step 2.
# Sign out at https://auth.<domain>/oauth2/sign_out.
{ config, pkgs, ... }:

let
  inherit (config.infra) domain proxyNetwork;

  # nixpkgs' build rather than the upstream image, like anubis: the version
  # moves with the flake and there is no digest to keep up with. No CA bundle:
  # every request it makes itself goes to forgejo over the proxy bridge.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "oauth2-proxy";
    tag = pkgs.oauth2-proxy.version;
    config.Entrypoint = [ "${pkgs.oauth2-proxy}/bin/oauth2-proxy" ];
  };
in
{
  # An env file, not a mounted one: docker re-reads it at every container
  # start, so it never pins a stale sops generation. See
  # docs/src/architecture/secrets.md.
  sops.templates."oauth2-proxy.env".content = ''
    OAUTH2_PROXY_CLIENT_ID=${config.sops.placeholder.oauth2_proxy_client_id}
    OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.oauth2_proxy_client_secret}
    OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.oauth2_proxy_cookie_secret}
  '';

  virtualisation.oci-containers.containers.oauth2-proxy = {
    image = "oauth2-proxy:${pkgs.oauth2-proxy.version}";
    imageFile = image;

    environmentFiles = [ config.sops.templates."oauth2-proxy.env".path ];

    cmd = [
      "--http-address=0.0.0.0:4180"
      # Nothing behind auth.<domain> itself: signed in, it answers 200 empty.
      "--upstream=static://200"
      # X-Forwarded-* believed from caddy's pinned address only, not from
      # every container that shares the bridge.
      "--reverse-proxy=true"
      "--trusted-proxy-ip=${config.infra.caddyIPv4}"

      "--redirect-url=https://auth.${domain}/oauth2/callback"
      # The session and CSRF cookies go to every <name>.<domain>, which is
      # what makes one sign-in cover every gated site and lets the callback
      # here read the CSRF cookie /oauth2/start set on the gated site. They
      # are HttpOnly and Secure, so no page script on any name can read them.
      "--cookie-domain=.${domain}"
      # Where the sign-in may send the browser back to. Without it the
      # original URL is "not in whitelist" and every sign-in lands on /.
      "--whitelist-domain=.${domain}"

      "--provider=oidc"
      "--provider-display-name=Forgejo"
      # Must equal the id_token's `iss` exactly, which is Forgejo's ROOT_URL
      # without its trailing slash (its discovery document says so).
      "--oidc-issuer-url=https://git.${domain}"
      # SPLIT ENDPOINTS. The browser goes to the public authorize page; the
      # server-side calls go straight to forgejo over the proxy bridge. Through
      # the public name they would hairpin through caddy and meet Anubis,
      # which challenges a Go HTTP client on any non-tool path — and the
      # token exchange would come back as a challenge, not a token.
      "--skip-oidc-discovery=true"
      "--login-url=https://git.${domain}/login/oauth/authorize"
      "--redeem-url=http://forgejo:4242/login/oauth/access_token"
      "--oidc-jwks-url=http://forgejo:4242/login/oauth/keys"
      "--code-challenge-method=S256"

      # oauth2-proxy only allowlists "emails". This makes the Forgejo username
      # the session's email, so a site's `allowed_emails` is a list of
      # usernames, compared exactly (checkAllowedEmails in 7.15.6). With the
      # claim not literally `email`, email_verified is not consulted at all.
      "--oidc-email-claim=preferred_username"
      # See the header: the per-site list is the gate.
      "--email-domain=*"

      # Straight to Forgejo instead of oauth2-proxy's own "Sign in with"
      # page, which would be one more click with only one button on it.
      "--skip-provider-button=true"
    ];

    networks = [ proxyNetwork ];

    # Holds its sessions in the cookie, nothing on disk.
    extraOptions = [
      "--user=65534:65534"
      "--read-only"
      "--security-opt=no-new-privileges:true"
      "--cap-drop=ALL"
    ];
  };
}
