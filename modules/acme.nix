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

      # The certificate directory is group-owned by `caddy`, not by `acme`.
      #
      # caddy no longer runs as root (see modules/containers/caddy.nix), and
      # root's ability to read 0640 files it does not own comes from
      # CAP_DAC_OVERRIDE — which that container drops. Group membership is what
      # replaces it: the directory is 0750 and the files 0640, so the caddy
      # account reads them because it IS the group, not because it is powerful.
      #
      # mailserver is unaffected: it still runs as root and keeps DAC_OVERRIDE.
      group = "caddy";
      reloadServices = [
        "docker-caddy.service"
        "docker-mailserver.service"
      ];
    };
  };
}
