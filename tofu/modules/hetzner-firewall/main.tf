# The outer of two firewalls. modules/firewall.nix is the inner one, and the
# two are kept deliberately similar: each is what survives a misconfiguration of
# the other. A port opened here but not there is still closed, and vice versa —
# so when a service is unreachable, check both.
#
# Hetzner's firewall is stateful on `in` and does not see traffic between the
# host and its own containers, so it has no equivalent of the forward-chain
# problem the nftables ruleset has to solve.

locals {
  anywhere = ["0.0.0.0/0", "::/0"]

  inbound = [
    { protocol = "udp", port = "41641", description = "Wireguard/Tailscale" },
    { protocol = "tcp", port = "22", description = "Forgejo SSH" },
    { protocol = "tcp", port = "2222", description = "Host sshd" },
    { protocol = "tcp", port = "25", description = "SMTP" },
    { protocol = "tcp", port = "465", description = "SMTPS" },
    { protocol = "tcp", port = "587", description = "SMTP Submission" },
    { protocol = "tcp", port = "993", description = "IMAPS" },
    { protocol = "tcp", port = "80", description = "HTTP" },
    { protocol = "tcp", port = "443", description = "HTTPS" },
    { protocol = "udp", port = "443", description = "HTTP/3" },
    { protocol = "tcp", port = "25565", description = "Minecraft" },
  ]

  outbound = [
    { protocol = "tcp", port = "53", description = "DNS TCP" },
    { protocol = "udp", port = "53", description = "DNS UDP" },
    { protocol = "tcp", port = "80", description = "HTTP" },
    { protocol = "tcp", port = "443", description = "HTTPS" },
    { protocol = "udp", port = "443", description = "QUIC / Tailscale DERP" },
    { protocol = "udp", port = "123", description = "NTP" },
    { protocol = "udp", port = "3478", description = "STUN (Tailscale)" },
    { protocol = "udp", port = "41641", description = "Tailscale direct" },
    { protocol = "tcp", port = "7844", description = "Cloudflare Tunnel TCP" },
    { protocol = "udp", port = "7844", description = "Cloudflare Tunnel UDP" },
    { protocol = "tcp", port = "25", description = "SMTP out" },
    # Server-to-server ssh on the host sshd port. Added during the CX33 -> CX43
    # migration so the old box could rsync directly to the new one.
    { protocol = "tcp", port = "2222", description = "Host sshd out" },
  ]
}

resource "hcloud_firewall" "main" {
  name = var.name

  dynamic "rule" {
    for_each = local.inbound
    content {
      direction   = "in"
      protocol    = rule.value.protocol
      port        = rule.value.port
      source_ips  = local.anywhere
      description = rule.value.description
    }
  }

  dynamic "rule" {
    for_each = local.outbound
    content {
      direction       = "out"
      protocol        = rule.value.protocol
      port            = rule.value.port
      destination_ips = local.anywhere
      description     = rule.value.description
    }
  }
}

# Separate from the server resource so a rule change is a firewall diff, not a
# server diff.
resource "hcloud_firewall_attachment" "main" {
  firewall_id = hcloud_firewall.main.id
  server_ids  = var.server_ids
}
