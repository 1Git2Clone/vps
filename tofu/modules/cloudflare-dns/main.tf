# Provider v5. Three things changed from the v4 resources this was ported from,
# and all three are silent if missed: the resource is cloudflare_dns_record (not
# cloudflare_record), `name` must be the full FQDN rather than a bare label, and
# `allow_overwrite` no longer exists — a record the provider does not already
# manage has to be imported instead of quietly adopted.
#
# ttl = 1 is Cloudflare's "automatic".
#
# DELIBERATELY NOT MANAGED HERE: the CNAMEs on the apex (hu-tao.dev) and www,
# which point at Netlify. The site is a static frontend hosted there on purpose —
# self-hosting it would mean a thirteenth container, running node, to maintain
# forever for something a CDN does for free.
#
# The provider only touches records it declares, so an apply cannot disturb them.
# The trap to avoid is "completing" this file by adding an apex record: that
# would fight Netlify for the same name. If you ever do want the apex here, move
# the site first, do not point it at the VPS and hope.
#
# The apex being a CNAME while also carrying MX, SPF and DMARC works because
# Cloudflare flattens apex CNAMEs — mail is unaffected by the frontend.

resource "cloudflare_dns_record" "a" {
  for_each = var.subdomains

  zone_id = var.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"
  content = var.vps_ip
  ttl     = 1
  proxied = false
}

# Tailnet-only names, pointing at the box's CGNAT address. Public DNS carrying
# a 100.x address that is unroutable from the internet, so the record resolves
# for everyone and connects for nobody outside the tailnet. The names are
# public either way — they are SANs on the certificate and reach the CT logs
# when it is issued.
#
# See var.tailnet_ipv4 for why this is an A record and not a CNAME to the
# node's MagicDNS name.
#
# for_each over an empty set while tailnet_ipv4 is unset, so the records simply
# do not exist until there is something to point them at.
resource "cloudflare_dns_record" "tailnet" {
  for_each = var.tailnet_ipv4 == "" ? toset([]) : var.tailnet_subdomains

  zone_id = var.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"
  content = var.tailnet_ipv4
  ttl     = 1
  proxied = false
}

# The second minecraft world is published on 25566, not the default 25565, so a
# bare A record is not enough — the client would have to be told the port. This
# is what lets players type "mc2.<domain>" and nothing else.
#
# The name carries the service and protocol in v5 (_minecraft._tcp.<host>);
# priority/weight/port/target live in `data`. Target is the A record above, not
# the IP: an SRV target must be a name.
resource "cloudflare_dns_record" "minecraft2_srv" {
  zone_id  = var.zone_id
  name     = "_minecraft._tcp.mc2.${var.domain}"
  type     = "SRV"
  priority = 0
  ttl      = 1

  data = {
    priority = 0
    weight   = 0
    port     = 25566
    target   = "mc2.${var.domain}"
  }

  # The A record has to exist before anything resolves the target.
  depends_on = [cloudflare_dns_record.a]
}

# MX must point at a name that resolves to the host itself, which is why smtp is
# in var.subdomains.
resource "cloudflare_dns_record" "mx" {
  zone_id  = var.zone_id
  name     = var.domain
  type     = "MX"
  content  = "smtp.${var.domain}"
  priority = 10
  ttl      = 1
}

# -all, not ~all: nothing but this host is authorised to send for the domain.
resource "cloudflare_dns_record" "spf" {
  zone_id = var.zone_id
  name    = var.domain
  type    = "TXT"
  content = "v=spf1 ip4:${var.vps_ip} -all"
  ttl     = 1
}

resource "cloudflare_dns_record" "dkim_cloudflare" {
  zone_id = var.zone_id
  name    = "cf2024-1._domainkey.${var.domain}"
  type    = "TXT"
  content = var.dkim_cloudflare_key
  ttl     = 1
}

# The private half of this one is in secrets.yaml and mounted into DMS. Changing
# one without the other breaks DKIM at every recipient.
resource "cloudflare_dns_record" "dkim_default" {
  zone_id = var.zone_id
  name    = "default._domainkey.${var.domain}"
  type    = "TXT"
  content = var.dkim_default_key
  ttl     = 1
}

resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  content = "v=DMARC1; p=quarantine; rua=${var.dmarc_rua}"
  ttl     = 1
}

resource "cloudflare_dns_record" "bsky" {
  zone_id = var.zone_id
  name    = "_atproto"
  type    = "TXT"
  content = var.bsky_record
  ttl     = 1
}

# ==============================================================================
# CAA — which certificate authorities may issue for this zone
# ==============================================================================
# Without these records, ANY of the ~150 CAs in the public trust stores can
# issue a certificate for hu-tao.dev, and a misissuance is a valid certificate
# for this domain in someone else's hands. DNSSEC does not help: a certificate
# is not a DNS answer, so signing the zone says nothing about who may sign for
# its name.
#
# THREE ISSUANCE PATHS FEED THIS LIST, and only one of them is this server.
# That the apex and www are Netlify's is already stated at the top of this file;
# what a CAA record needs on top of it is WHICH CA each path uses, and that came
# from inspecting the live certificates on 2026-09-20. A list written from
# modules/acme.nix alone would have been right about the VPS and would have
# broken the other two.
#
#   letsencrypt.org  The VPS: lego issues the apex certificate and its ten SANs
#                    over DNS-01 (modules/acme.nix). AND Netlify, which serves
#                    the apex itself — hu-tao.dev's A records are 75.2.60.5 and
#                    99.83.231.61, which are Netlify, not this server. Netlify
#                    issues through Let's Encrypt too, so one entry covers both.
#
#   pki.goog         Cloudflare Universal SSL. www.hu-tao.dev is a PROXIED
#                    CNAME, so Cloudflare terminates TLS for it at its edge
#                    using a certificate of its own — currently Google Trust
#                    Services, and a WILDCARD covering hu-tao.dev and
#                    *.hu-tao.dev. `cansignhttpexchanges=yes` is the spelling
#                    Cloudflare documents for this CA, not decoration.
#
# NO issuewild RECORDS, DELIBERATELY. RFC 8659: when no issuewild record is
# present, `issue` governs wildcard issuance as well. The tempting hardening
# here is `issuewild ";"` to forbid wildcards outright — that would break the
# Cloudflare edge certificate above, because it IS a wildcard, and the break
# would not surface until renewal roughly 30 days before expiry with nothing in
# this repo to point at.
#
# CLOUDFLARE MAY PUBLISH MORE CAA RECORDS THAN THESE, and they will never
# appear in a plan. When Cloudflare is the DNS provider it adds its own CAs on
# your behalf, so Universal SSL keeps renewing if it rotates from Google to
# ssl.com or sectigo.com. Those records are live and are not managed here:
# `dig CAA hu-tao.dev` is the truth, this resource is only the part tofu owns.
resource "cloudflare_dns_record" "caa" {
  # Keyed by CA rather than generated from the value, so a state address stays
  # readable and adding an issuer is one line rather than a re-index.
  for_each = {
    letsencrypt = { tag = "issue", value = "letsencrypt.org" }
    google      = { tag = "issue", value = "pki.goog; cansignhttpexchanges=yes" }
    iodef       = { tag = "iodef", value = "mailto:${var.caa_iodef}" }
  }

  zone_id = var.zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 1

  data = {
    # 0 = non-critical. A CA that does not understand the tag may proceed;
    # every CA understands issue and iodef, so this costs nothing and avoids
    # the failure mode where a critical unknown tag blocks all issuance.
    flags = 0
    tag   = each.value.tag
    value = each.value.value
  }
}
