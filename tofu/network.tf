# ==============================================================================
# The private network
# ==============================================================================
# One /16 with a single /24 subnet, with the VPS attached and NOTHING ELSE.
#
# It was built to join the VPS and the CI runner, and the runner is deliberately
# not on it. Hetzner cloud firewalls filter the PUBLIC interface only: private
# traffic is never inspected, and there are no ACLs, security groups or route
# policy for it. So the only cloud-level control over a private path is binary —
# attached, or not — and "not" is the one that cannot be undone by a typo.
#
# Filtering it host-side was the alternative and it is weaker, because
# modules/firewall.nix accepts nine ports with no iifname. The moment a private
# interface came up on the VPS, 10.0.1.3 could open new connections to every one
# of them. See docs/superpowers/specs/2026-09-18-ci-runner-host-design.md.
#
# What the runner gets instead: HTTPS to git.<domain> over the public internet,
# like any other client, and ssh FROM the VPS. One way, by construction.
#
# The network stays because it costs nothing and the next box that is actually
# trusted — a second app host, a database — should be on it. Both locations are
# in eu-central, and a Hetzner network is scoped to a network ZONE rather than a
# location, so fsn1 and nbg1 could share it. Traffic on it is free.
#
# WHAT THIS DOES NOT DO: attaching a server here gives it a second NIC, it does
# not configure one. Until the NixOS side brings that interface up (Hetzner
# hands out the address over DHCP on the private NIC), 10.0.1.x is a Hetzner
# fact and not a reachable address. That is the next pass, with the runner move.
#
# Note also that hcloud firewalls filter the PUBLIC interface only — main-firewall
# does not see this traffic at all. What governs the private link is the host's
# own nftables in modules/firewall.nix, whose forward chain is policy-drop with
# an interface allow-list. Expect to add the private NIC there before anything
# actually flows.

resource "hcloud_network" "main" {
  name = "hu-tao"

  # Deliberately roomy and deliberately NOT overlapping docker. The host runs
  # docker with a pinned bip and per-job bridges in 172.16/12 (see
  # infra.dockerBridgeGateway and forgejo-runner.nix), so 10.0.0.0/16 cannot
  # collide with a bridge the daemon invents on its own. A collision here does
  # not fail loudly — it silently blackholes one side.
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id = hcloud_network.main.id
  type       = "cloud"

  # The zone, not a location. Both boxes are eu-central; see the header.
  network_zone = "eu-central"

  # A /24 out of the /16 above, leaving room to add more subnets later without
  # renumbering this one. Hetzner reserves .1 as the gateway, so usable host
  # addresses start at .2.
  ip_range = "10.0.1.0/24"
}

# One attachment, pinning an explicit address rather than letting Hetzner assign
# one: it ends up in NixOS config and in any future firewall rule, so it must not
# change when a server is detached and reattached.
#
# subnet_id, NOT network_id: attaching to a network whose subnet does not exist
# yet fails, and naming the subnet is what orders the two correctly.

resource "hcloud_server_network" "vps" {
  server_id = hcloud_server.vps.id
  subnet_id = hcloud_network_subnet.main.id
  ip        = "10.0.1.2"
}
