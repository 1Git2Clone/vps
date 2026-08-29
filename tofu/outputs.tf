output "vps_ipv4" {
  description = "Public IPv4 of the VPS. Survives a rebuild of the server."
  value       = hcloud_primary_ip.main.ip_address
}

output "server_id" {
  description = "Hetzner Cloud server ID."
  value       = hcloud_server.vps.id
}

output "hostnames" {
  description = "Hostnames published at the VPS."
  value       = module.dns.hostnames
}
