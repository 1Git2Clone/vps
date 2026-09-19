module "hetzner-firewall" {
  source = "./modules/hetzner-firewall"

  providers = {
    hcloud = hcloud
  }

  name = "main-firewall"

  # Both boxes during the migration. See var.legacy_server_ids — dropping the
  # old server from this list disarms its firewall rather than ignoring it.
  #
  # The CI runner is deliberately NOT here. The console attached this firewall to
  # it at creation out of habit; it has its own in runner-firewall.tf now, and
  # this attachment being authoritative over applied_to is exactly what detaches
  # it when that one attaches.
  server_ids = concat([hcloud_server.vps.id], var.legacy_server_ids)

  # The jump-host egress rule. See var.runner_ipv4s for why this is an explicit
  # list rather than hcloud_server.runner[*].ipv4_address.
  runner_ips = values(var.runner_ipv4s)
}
