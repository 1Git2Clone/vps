# ==============================================================================
# Certificates
# ==============================================================================
# Replaces the certbot/dns-cloudflare container and its nightly cron entry.
# One certificate, DNS-01 via Cloudflare, renewed by a systemd timer that ships
# with NixOS.
#
# Two things the certbot setup had to be careful about disappear here:
#
#   * The lineage name. certbot names a lineage after the FIRST -d, so
#     reordering the domain list silently issued a second certificate under a
#     new name while the readers kept reading the old, no-longer-renewed one.
#     Here the certificate IS named `infra.domain` and the rest are SANs.
#
#   * Reloading the readers. certbot needed a deploy-hooks directory;
#     `reloadServices` restarts caddy and DMS after a successful renewal.
#     oci-containers deliberately defines no ExecReload, so
#     try-reload-or-restart resolves to a restart — which is what a container
#     holding an old certificate in memory needs anyway.
#
# The one-shot `certonly` invocation has no equivalent and needs none: the
# acme-<domain>.service unit issues on first activation.
{ config, ... }:

let
  inherit (config.infra) domain;
in
{
  # lego reads the token from the environment. A sops *template* rather than a
  # raw secret because what lego wants is KEY=value, not the bare token.
  sops.templates."acme-cloudflare.env".content = ''
    CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.cloudflare_api_token}
  '';

  security.acme = {
    acceptTerms = true;
    defaults.email = config.infra.acmeEmail;

    certs.${domain} = {
      inherit domain;
      extraDomainNames = map (sub: "${sub}.${domain}") config.infra.certSubdomains;

      dnsProvider = "cloudflare";
      environmentFile = config.sops.templates."acme-cloudflare.env".path;
      # DNS-01 only ever touches _acme-challenge TXT records, so no domain here
      # needs an A record or a reachable port 80 — which is why the apex itself
      # can be on the certificate.
      dnsPropagationCheck = true;

      # /var/lib/acme/<domain> is root:acme 0750. Both readers bind-mount the
      # directory and run as root inside the container, which on this host IS
      # root, so no group membership is needed on either side.
      reloadServices = [
        "docker-caddy.service"
        "docker-mailserver.service"
      ];
    };
  };
}
