output "a_record_ids" {
  description = "Record ID per subdomain."
  value       = { for name, record in cloudflare_dns_record.a : name => record.id }
}

output "hostnames" {
  description = "Every hostname this module publishes at the VPS."
  value       = [for name in var.subdomains : "${name}.${var.domain}"]
}
