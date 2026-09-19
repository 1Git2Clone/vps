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

output "runner_ipv4s" {
  description = <<-EOT
    The live runners' public IPv4s, by server name. Read this after an apply
    that replaced a box: the new address has to be copied into BOTH
    var.runner_ipv4s (the cloud firewall) and infra.runnerIPv4s in
    modules/options.nix (the VPS's nftables output chain), and the VPS
    redeployed, before `ssh -J vps` works again.
  EOT
  value       = { for name, srv in hcloud_server.runner : name => srv.ipv4_address }
}
