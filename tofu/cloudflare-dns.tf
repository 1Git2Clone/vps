module "dns" {
  source = "./modules/cloudflare-dns"

  providers = {
    cloudflare = cloudflare
  }

  zone_id = var.cloudflare_zone_id
  domain  = var.domain

  # From the primary IP rather than a variable: the address a record points at
  # and the address the server actually has cannot disagree this way.
  vps_ip = hcloud_primary_ip.main.ip_address

  tailnet_host = var.tailnet_host

  dkim_cloudflare_key = var.dkim_cloudflare_key
  dkim_default_key    = var.dkim_default_key
  dmarc_rua           = var.dmarc_rua

  bsky_record = var.bsky_record
}
