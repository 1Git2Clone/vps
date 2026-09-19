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
    { protocol = "tcp", port = "2222", description = "Host sshd (NixOS; 22 belongs to forgejo)" },
    { protocol = "tcp", port = "25", description = "SMTP" },
    { protocol = "tcp", port = "465", description = "SMTPS" },
    { protocol = "tcp", port = "587", description = "SMTP Submission" },
    { protocol = "tcp", port = "993", description = "IMAPS" },
    { protocol = "tcp", port = "80", description = "HTTP" },
    { protocol = "tcp", port = "443", description = "HTTPS" },
    { protocol = "udp", port = "443", description = "HTTP/3" },
    { protocol = "tcp", port = "25565", description = "Minecraft" },
    { protocol = "tcp", port = "25566", description = "Minecraft (second world)" },
  ]

  outbound = [
    { protocol = "tcp", port = "53", description = "DNS TCP" },
    { protocol = "udp", port = "53", description = "DNS UDP" },
    { protocol = "tcp", port = "80", description = "HTTP" },
    { protocol = "tcp", port = "443", description = "HTTPS" },
    { protocol = "udp", port = "443", description = "QUIC / Tailscale DERP" },
    { protocol = "udp", port = "123", description = "NTP" },
    { protocol = "udp", port = "3478", description = "STUN (Tailscale)" },
    { protocol = "udp", port = "41641", description = "Tailscale direct (avoids DERP relay)" },
    { protocol = "tcp", port = "7844", description = "Cloudflare Tunnel TCP" },
    { protocol = "udp", port = "7844", description = "Cloudflare Tunnel UDP" },
    { protocol = "tcp", port = "25", description = "SMTP out" },
    # Server-to-server ssh on the host sshd port. Added during the CX33 -> CX43
    # migration so the old box could rsync directly to the new one.
    { protocol = "tcp", port = "2222", description = "Host sshd, server-to-server" },
  ]

  # Egress ssh to the CI runners, one rule covering all of them. This is the
  # PERMANENT admin path, not install scaffolding: the runners are deliberately
  # off the tailnet, so `ssh -J vps root@<runner>` is the only way in and it
  # needs the VPS to originate a connection on 22.
  #
  # Built as a list to concatenate rather than written inline so an empty
  # var.runner_ips produces NO RULE, instead of one with an empty destination
  # list -- which hcloud reads as "anywhere", quietly turning a scoped rule into
  # an open one at the exact moment the list is misconfigured.
  runner_ssh = length(var.runner_ips) == 0 ? [] : [
    {
      protocol        = "tcp"
      port            = "22"
      description     = "ssh to the CI runners (jump host)"
      destination_ips = var.runner_ips
    },
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
    for_each = concat(local.outbound, local.runner_ssh)
    content {
      direction = "out"
      protocol  = rule.value.protocol
      port      = rule.value.port
      # Defaults to anywhere; an entry may narrow it. try() rather than lookup()
      # because these objects are a tuple of differing shapes, and only try()
      # tolerates the attribute being absent on most of them.
      destination_ips = try(rule.value.destination_ips, local.anywhere)
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
