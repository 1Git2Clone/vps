module "hetzner-firewall" {
  source = "./modules/hetzner-firewall"

  providers = {
    hcloud = hcloud
  }

  name = "main-firewall"

  # Both boxes during the migration. See var.legacy_server_ids — dropping the
  # old server from this list disarms its firewall rather than ignoring it.
  server_ids = concat([hcloud_server.vps.id], var.legacy_server_ids)
}
