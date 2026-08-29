output "firewall_id" {
  description = "ID of the edge firewall."
  value       = hcloud_firewall.main.id
}

output "attachment_id" {
  description = "ID of the firewall-to-server attachment."
  value       = hcloud_firewall_attachment.main.id
}
