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
