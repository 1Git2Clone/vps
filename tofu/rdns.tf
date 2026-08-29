# ==============================================================================
# Reverse DNS
# ==============================================================================
# The single most important record for mail deliverability, and until now it was
# set by hand in the Hetzner console — invisible to review and impossible to
# notice going missing.
#
# It belongs to the PRIMARY IP, not to the server. That is what makes the
# migration safe: moving hcloud_primary_ip.main to a different machine carries
# this PTR with it, so the new box inherits smtp.<domain> the moment it holds
# the address. No ticket, no propagation wait, no reputation reset.
#
# Three things must agree or mail gets filtered, and this is one of them:
#   PTR (here)  ==  DMS's container hostname  ==  the MX target
# See modules/containers/mailserver.nix for the other two.
resource "hcloud_rdns" "primary_ipv4" {
  primary_ip_id = hcloud_primary_ip.main.id
  ip_address    = hcloud_primary_ip.main.ip_address
  dns_ptr       = "smtp.${var.domain}"
}

# No IPv6 PTR, matching what is live today. Docker gives its containers no IPv6
# address, so postfix inside DMS has no IPv6 route to send over and never
# presents an IPv6 address to a recipient. Setting a PTR here would be harmless
# but would also imply IPv6 mail works, which it does not — the thing to change
# first would be docker's networking, not DNS.
