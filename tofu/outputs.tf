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

output "dnssec_ds" {
  description = <<-EOT
    The DS record to publish AT THE REGISTRAR, not in this zone. Paste it into
    the registrar's DNSSEC section for the domain; the `.dev` registry puts it
    in the parent zone, and only then does anything validate.

    Public by definition — a DS is served out of the parent zone to anyone who
    asks for it — so this is deliberately NOT marked sensitive. The private
    signing key never leaves Cloudflare and never appears in this state.

    Read the parts individually from `dnssec_ds_parts` if the registrar wants
    key tag / algorithm / digest type / digest in separate fields, which most
    of them do.
  EOT
  value       = cloudflare_zone_dnssec.main.ds
}

output "dnssec_ds_parts" {
  description = "The same DS, split, for registrars whose form has four boxes."
  value = {
    key_tag          = cloudflare_zone_dnssec.main.key_tag
    algorithm        = cloudflare_zone_dnssec.main.algorithm
    digest_type      = cloudflare_zone_dnssec.main.digest_type
    digest           = cloudflare_zone_dnssec.main.digest
    digest_algorithm = cloudflare_zone_dnssec.main.digest_algorithm
    public_key       = cloudflare_zone_dnssec.main.public_key
  }
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
